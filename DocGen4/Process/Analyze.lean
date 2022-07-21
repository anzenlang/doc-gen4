/-
Copyright (c) 2022 Henrik Böving. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Henrik Böving
-/

import Lean
import Std.Data.HashMap
import Std.Data.HashSet

import DocGen4.Process.Base
import DocGen4.Process.Hierarchy
import DocGen4.Process.DocInfo

namespace DocGen4.Process

open Lean Meta Std

/--
Member of a module, either a declaration or some module doc string.
-/
inductive ModuleMember where
| docInfo (info : DocInfo) : ModuleMember
| modDoc (doc : ModuleDoc) : ModuleMember
deriving Inhabited

/--
A Lean module.
-/
structure Module where
  /--
  Name of the module.
  -/
  name : Name
  /--
  All members of the module, sorted according to their line numbers.
  -/
  members : Array ModuleMember
  deriving Inhabited

/--
The result of running a full doc-gen analysis on a project.
-/
structure AnalyzerResult where
  /--
  The map from module names to indices of the `moduleNames` array.
  -/
  name2ModIdx : HashMap Name ModuleIdx
  /--
  The list of all modules, accessible nicely via `name2ModIdx`.
  -/
  moduleNames : Array Name
  /--
  A map from module names to information about these modules.
  -/
  moduleInfo : HashMap Name Module
  /--
  An adjacency matrix for the import relation between modules, indexed
  my the values in `name2ModIdx`.
  -/
  importAdj : Array (Array Bool)
  deriving Inhabited

namespace ModuleMember

def getDeclarationRange : ModuleMember → DeclarationRange
| docInfo i => i.getDeclarationRange
| modDoc i => i.declarationRange

/--
An order for module members, based on their declaration range.
-/
def order (l r : ModuleMember) : Bool :=
  Position.lt l.getDeclarationRange.pos r.getDeclarationRange.pos

def getName : ModuleMember → Name
| docInfo i => i.getName
| modDoc _ => Name.anonymous

def getDocString : ModuleMember → Option String
| docInfo i => i.getDocString
| modDoc i => i.doc

end ModuleMember

def getRelevantModules (imports : List Name) : MetaM (HashSet Name) := do
  let env ← getEnv
  let mut relevant := .empty
  for module in env.header.moduleNames do
    for import in imports do
      if import == module then
        relevant := relevant.insert module
  pure relevant

inductive AnalyzeTask where
| loadAll (load : List Name) : AnalyzeTask
| loadAllLimitAnalysis (analyze : List Name) : AnalyzeTask

def AnalyzeTask.getLoad : AnalyzeTask → List Name
| loadAll load => load
| loadAllLimitAnalysis load => load

def getAllModuleDocs (relevantModules : Array Name) : MetaM (HashMap Name Module) := do
  let env ← getEnv
  let mut res := mkHashMap relevantModules.size
  for module in relevantModules do
    let modDocs := getModuleDoc? env module |>.getD #[] |>.map .modDoc
    res := res.insert module (Module.mk module modDocs)
  pure res

-- TODO: This is definitely not the most efficient way to store this data
def buildImportAdjMatrix (allModules : Array Name) : MetaM (Array (Array Bool)) := do
  let env ← getEnv
  let mut adj := Array.mkArray allModules.size (Array.mkArray allModules.size false)
  for moduleName in allModules do
    let some modIdx := env.getModuleIdx? moduleName | unreachable!
    let moduleData := env.header.moduleData.get! modIdx
    for imp in moduleData.imports do
      let some importIdx := env.getModuleIdx? imp.module | unreachable!
      adj := adj.set! modIdx (adj.get! modIdx |>.set! importIdx true)
  pure adj

/--
Run the doc-gen analysis on all modules that are loaded into the `Environment`
of this `MetaM` run and mentioned by the `AnalyzeTask`.
-/
def process (task : AnalyzeTask) : MetaM (AnalyzerResult × Hierarchy) := do
  let env ← getEnv
  let relevantModules ← match task with
    | .loadAll _ => pure $ HashSet.fromArray env.header.moduleNames
    | .loadAllLimitAnalysis analysis => getRelevantModules analysis
  let allModules := env.header.moduleNames

  let mut res ← getAllModuleDocs relevantModules.toArray

  for (name, cinfo) in env.constants.toList do
    let some modidx := env.getModuleIdxFor? name | unreachable!
    let moduleName := env.allImportedModuleNames.get! modidx
    if !relevantModules.contains moduleName then
      continue

    try
      let config := {
        maxHeartbeats := 5000000,
        options := ←getOptions,
        fileName := ←getFileName,
        fileMap := ←getFileMap
      }
      let analysis := Prod.fst <$> Meta.MetaM.toIO (DocInfo.ofConstant (name, cinfo)) config { env := env } {} {}
      if let some dinfo ← analysis then
        let moduleName := env.allImportedModuleNames.get! modidx
        let module := res.find! moduleName
        res := res.insert moduleName {module with members := module.members.push (ModuleMember.docInfo dinfo)}
    catch e =>
      IO.println s!"WARNING: Failed to obtain information for: {name}: {←e.toMessageData.toString}"

  let adj ← buildImportAdjMatrix allModules

  -- TODO: This could probably be faster if we did sorted insert above instead
  for (moduleName, module) in res.toArray do
    res := res.insert moduleName {module with members := module.members.qsort ModuleMember.order}

  let hierarchy := Hierarchy.fromArray allModules
  let analysis := {
    name2ModIdx := env.const2ModIdx,
    moduleNames := allModules,
    moduleInfo := res,
    importAdj := adj
  }
  pure (analysis, hierarchy)

def filterMapDocInfo (ms : Array ModuleMember) : Array DocInfo :=
  ms.filterMap filter
  where
    filter : ModuleMember → Option DocInfo
    | ModuleMember.docInfo i => some i
    | _ => none

end DocGen4.Process
