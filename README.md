# swamp.el

An Emacs transient interface for the [swamp](https://github.com/systeminit/swamp) AI-native automation CLI.

## Features

- Transient menus for all swamp commands (models, workflows, extensions, data)
- All output rendered via Emacs-native `tabulated-list-mode` and `special-mode` buffers — no terminal emulator required
- `RET` on any list row drills into a detail buffer
- Status values (`succeeded`, `failed`, `running`) are highlighted with distinct faces
- `swamp-jump-to-last-result` jumps back to the most recent result buffer
- `swamp-repo-dir` customizable for per-project repo targeting

## Requirements

- Emacs 29.1+
- [transient](https://github.com/magit/magit/tree/main/lisp) 0.5.0+
- The `swamp` CLI on your `PATH`

## Installation

### straight.el / Doom Emacs

```elisp
(package! swamp
  :recipe (:host github
           :repo "webframp/emacs-swamp"
           :files ("swamp.el")))
```

### use-package + straight.el

```elisp
(use-package swamp
  :straight (:host github :repo "webframp/emacs-swamp" :files ("swamp.el")))
```

## Usage

Call `M-x swamp-dispatch` (or bind it) to open the root transient menu:

```
Swamp AI-native automation

Models                   Workflows
m  Model                 w  Workflow
d  data query            e  Extension
                         S  summarize
                         b  last result
```

### Keybinding example

```elisp
(global-set-key (kbd "C-c s") #'swamp-dispatch)
```

### Doom Emacs keybinding

```elisp
(map! :leader :prefix "o s" "" #'swamp-dispatch)
```

### Submenus

| Menu | Key | Commands |
|---|---|---|
| Model | `m` | search (`s`), get (`g`), output get (`o`), method run (`r`), validate (`v`) |
| Workflow | `w` | search (`s`), get (`g`), run (`r`), history (`h`) |
| Extension | `e` | search (`s`), pull (`p`) |

### Direct commands

All commands are also callable directly:

| Command | Description |
|---|---|
| `swamp-model-search` | Search models; results in a table, `RET` opens detail |
| `swamp-model-get` | Show model detail (type, version, methods) |
| `swamp-model-method-run` | Run a method; blocks until complete |
| `swamp-model-output-get` | Show latest output artifact metadata |
| `swamp-model-validate` | Validate model definition with pass/fail per check |
| `swamp-workflow-search` | Search workflows; `RET` opens detail |
| `swamp-workflow-run` | Run a workflow; shows job/step tree on completion |
| `swamp-workflow-history` | List recent runs with status and duration |
| `swamp-workflow-get` | Show workflow definition detail |
| `swamp-extension-search` | Search the extension registry |
| `swamp-extension-pull` | Pull an extension; reports `name@version` on success |
| `swamp-data-query` | Run a CEL predicate against data artifacts |
| `swamp-summarize` | Show recent activity summary |
| `swamp-jump-to-last-result` | Jump to the most recently opened result buffer |

## Customization

```elisp
;; Path to the swamp executable (default: "swamp")
(setq swamp-executable "/usr/local/bin/swamp")

;; Pin commands to a specific repo directory
(setq swamp-repo-dir "~/src/my-swamp-repo")
```

## Buffer conventions

| Buffer | Mode | Notes |
|---|---|---|
| `*swamp-models*` | `tabulated-list-mode` | `RET` → model detail |
| `*swamp-model:<name>*` | `special-mode` | — |
| `*swamp-run:<model>/<method>*` | `special-mode` | — |
| `*swamp-output:<name>*` | `special-mode` | — |
| `*swamp-validate:<name>*` | `special-mode` | Pass/fail per validation |
| `*swamp-workflows*` | `tabulated-list-mode` | `RET` → workflow detail |
| `*swamp-workflow:<name>*` | `special-mode` | — |
| `*swamp-workflow-run:<name>*` | `special-mode` | Job/step tree with status |
| `*swamp-history:<name>*` | `tabulated-list-mode` | — |
| `*swamp-extensions*` | `tabulated-list-mode` | — |
| `*swamp-data*` | `tabulated-list-mode` | — |
| `*swamp-summary*` | `tabulated-list-mode` | — |

## Running tests

```sh
emacs --batch -l ert \
      -l swamp.el \
      -l test-swamp.el \
      -f ert-run-tests-batch-and-exit
```

## License

GPL-3.0-or-later
