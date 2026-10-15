# Project folders, locking and packages (`.genstudio`)

GenStudio works like InDesign or Illustrator: a project can live in a folder you choose, its finished artwork is saved there as ordinary files, and the folder can be handed to a colleague, archived, or reopened later.

```
Client Campaign/                    ← the project folder you chose
  Client Campaign.genstudio         ← the workflow, kept current on every autosave
  Links/
    images/  Shot 11A Hand Approaches.png     ← named after the node's heading
    video/   Door Opens.mp4
    prompts/ Hallway Prompt.txt
  Models Used.txt                   ← which models the workflow uses, and where to get them
```

## Where things live

| | Lives in | Why |
|---|---|---|
| Workflow, settings, locked finals, inputs | the project folder | It is the file you own and hand over. |
| **Drafts**: unlocked generations, earlier takes, run history | the app library (`~/Library/Application Support/GenStudio`) | Keeps the folder to finished work. Drafts are cheap to regenerate. |
| Models, runtime | the app library | Shared by every project; never packaged. |

The library also keeps a copy of every project, so a missing or unplugged project folder never loses work: the project stays safe in the app and the folder file is rewritten when the folder is back.

## Locking a node (the lock tab on the card)

The round tab on a node's bottom edge is a lock. **Open** (grey): the node is being worked on; takes accumulate and it can run. **Locked** (green): the chosen result is saved to `Links/` under the node's heading, the node cannot generate, and connected nodes receive that saved file. A red lock means the saved file went missing outside the app.

- Locking asks for a project folder if the project has none yet. Lockable nodes: anything that produces takes (image, upscale, video…), text-producing nodes, and Prompt nodes (saved as `.txt`, then read-only).
- **Heading = file name.** Renaming a locked node (on the card, in the inspector, or in the Images sidebar) renames its file and updates the link. Undo and redo rename it back. Two nodes with the same heading get `_2`; a file you put there is never overwritten.
- **Downstream and speed.** A locked node is treated like an input: its file is the value downstream nodes receive, nothing behind it is planned or run, and it is left out of the run-plan estimate. Changing upstream nodes does not reach it.
- **Unlocking** returns the node to draft but keeps the saved file; locking again replaces that same file.
- If a locked file is missing, runs that depend on it stop with a clear message instead of quietly drawing a new one.
- **Quitting** with unlocked generations in a folder-bound project asks: *Lock All and Quit*, *Quit, Keep as Drafts* or *Cancel*. **Workflow ▸ Lock All Generations** does it any time.
- Duplicating a node makes a draft; duplicating a project makes an unbound copy.

## Prompts

A Prompt node's inspector has **Load from File…** (copies a `.txt` into the prompt, so the project stays self-contained) and **Save As…** (writes the prompt to any `.txt` to reuse elsewhere). Locking a prompt saves it to `Links/prompts/`.

## File menu

- **New Project in Folder…** (⇧⌘N) creates a project in a folder, or opens the project already saved there.
- **Set Project Folder…** binds the current project to a folder (creates `Links/images|video|prompts`). One folder holds one project; a folder that already holds a different project's file is refused.
- **Open Project File…** (⌘O) or double-click a `.genstudio` in Finder. If the project is already in the library from that folder it is shown, otherwise it is added and keeps working in that folder. Every identity is regenerated on the way in, so it never collides with a copy in the library.
- **Package Project…** (⌥⌘P) is InDesign's *Collect for Output*: it copies everything the workflow references (inputs from Desktop or Downloads, last results) into a folder's `Links/`, writes the `.genstudio` and `Models Used.txt`, then offers **Remove from Library**. Files already in the project's own `Links` stay in place. Nothing is deleted from the folder.

## Formats and compatibility

- `.genstudio` is JSON with `formatVersion` (currently 1). A newer version is refused untouched with a clear message. Paths inside are relative (`Links/images/…`) and resolved against the file's folder; nothing machine-specific is stored (the folder path lives only in the app library).
- `homeFolder` on a project and `finalized` on a node are optional, so older workflow files load unchanged and gain no new keys until used.

## Code

`ProjectHome.swift` (folder layout, naming, `FinalRecord`), `FinalLocking.swift` (lock/unlock, folder binding, heading→file sync), `FinalBadge.swift` (lock tab, inspector section, prompt load/save), `ProjectMirror.swift` (the live `.genstudio`), `ProjectPackage.swift` (Package, reader, `Models Used`), `ProjectPackageModel.swift` (panels, remove-from-library, open). Tests: `ProjectFolderTests.swift`, `ProjectPackageTests.swift`.

## Known limits

- Drafts stay in the app library, not in the project folder. Reopening a project in a fresh library shows locked finals but no drafts.
- Moving a project folder is not tracked: missing files are reported, but there is no in-app *Relink* panel yet.
- Text finals show from the saved record, not by re-reading the `.txt`; editing that file outside the app does not change the node.
- `Models Used.txt` lists each node's selected model only (not LoRAs or the prompt-compiler model).
