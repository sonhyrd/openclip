# OpenClip

A macOS clipboard and selection utility whose AI actions transform selected text through a
user-chosen provider. This glossary covers the vocabulary of the AI provider layer.

## Language

**Wire id**:
The exact string sent to a command-line tool over `--model` or `-m`. It may be dated
(`claude-sonnet-4-5-20250929`) or undated; the human never has to read it.
_Avoid_: Model id, model string, model number

**Display name**:
What the human sees for a model, such as "Sonnet 4.5". Never a date stamp or a wire id.
_Avoid_: Model name, label

**Catalog**:
The list of models a command-line tool itself carries, on this machine. The only source a model
picker may be built from.
_Avoid_: Model list, supported models, hard-coded list

**CLI provider**:
An AI provider that runs the user's own locally installed, locally authenticated command-line tool
on the user's subscription. It handles no credential.
_Avoid_: Local provider, subscription provider, shell provider
