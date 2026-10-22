# swamp.el

An Emacs transient interface for the [swamp](https://github.com/systeminit/swamp) AI-native automation CLI.

## Features

- Transient menus for all swamp commands (models, workflows, extensions, data)
- All output rendered via Emacs-native `tabulated-list-mode` and `special-mode` buffers — no terminal emulator required
- `RET` on any list row drills into a detail buffer
- Status values (`succeeded`, `failed`, `running`) are highlighted with distinct faces
- `swamp-jump-to-last-result` jumps back to the most recent result buffer
- `swamp-repo-dir` customizable for per-project repo targeting
- `swamp-present` builds, previews, outlines and prints reveal.js decks from
  Org or Markdown buffers through the `@webframp/presentation` extension

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
           :files ("swamp.el" "swamp-present.el")))
```

### use-package + straight.el

```elisp
(use-package swamp
  :straight (:host github :repo "webframp/emacs-swamp"
             :files ("swamp.el" "swamp-present.el")))
(use-package swamp-present :straight nil :after swamp)
```

Leave `swamp-present.el` out of `:files` if you do not build presentations.

## Usage

Call `M-x swamp-dispatch` (or bind it) to open the root transient menu:

```
Swamp AI-native automation

Models                   Workflows
m  Model                 w  Workflow
d  data query            e  Extension
p  present               S  summarize
                         b  last result
```

`p` appears once `swamp-present` is loaded.

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

## Presentations

`swamp-present` builds the Org or Markdown deck in the current buffer with
the [`@webframp/presentation`](https://github.com/webframp/swamp-extensions/tree/main/presentation)
extension. Each build is stored as versioned swamp data; Emacs only runs
swamp and opens what it returns. Set the extension up once per swamp
repository:

```sh
swamp extension pull @webframp/presentation
swamp model create @webframp/presentation/deck talks
```

| Command | Key in `swamp-present-dispatch` | Does |
|---|---|---|
| `swamp-present-build` | `b` | Build the deck; with `C-u`, self-contained |
| `swamp-present-preview` | `p` | Build it and open it in a browser; with `C-u`, self-contained |
| `swamp-present-pdf` | `P` | Build it, print it to PDF, and open the PDF; with `C-u`, self-contained, so printing needs no network |
| `swamp-present-outline` | `o` | List slides, words of speaker notes and images, without building |
| `swamp-present-cancel` | `k` | Stop the swamp commands swamp-present started |

The buffer is saved first if you agree. Builds run in the background, and
the echo area reports the slide count and any warnings, which collect in
`*swamp-present*` along with swamp's error output. A command still running
after `swamp-present-timeout` seconds (default 600; nil for never) is
stopped.

- `swamp-present-deck` (default `"talks"`) names the deck model instance.
  An Org buffer can name another with `#+SWAMP_DECK: conference`.
- `swamp-present-name` sets the deck's name for one buffer, as a file-local
  variable, when two sources share a file name.
- `swamp-present-output-directory` is where previews are written, as
  `swamp-present-<instance>-<name>.html` and `.pdf`. The default is
  `swamp-present/` under `user-emacs-directory`, created readable by you alone.
  Each preview overwrites the last, so a browser tab only needs reloading, and
  an open PDF buffer is refreshed in place.
- `swamp-present-deck`, `#+SWAMP_DECK:` and `swamp-present-name` must be plain
  names (letters, digits, `.`, `_`, `-`; deck names lowercase, at most 63
  characters); anything else is refused before swamp runs.

Doom Emacs keybindings, for example (repeat with `:after markdown-mode` and
`:map markdown-mode-map` for Markdown):

```elisp
(map! :after org
      :map org-mode-map
      :localleader
      (:prefix ("S" . "swamp present")
       "b" #'swamp-present-build
       "p" #'swamp-present-preview
       "P" #'swamp-present-pdf
       "o" #'swamp-present-outline))
```

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
| `*swamp-outline:<name>*` | `tabulated-list-mode` | Slides of a deck, from `swamp-present-outline` |
| `*swamp-present*` | `fundamental-mode` | swamp-present's build warnings and swamp's error output |

## Running tests

```sh
emacs --batch -l ert \
      -l swamp.el \
      -l test-swamp.el \
      -f ert-run-tests-batch-and-exit

emacs --batch -l ert -L . \
      -l swamp-present.el \
      -l test-swamp-present.el \
      -f ert-run-tests-batch-and-exit
```

## License

GPL-3.0-or-later
