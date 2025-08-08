# Project: Cursor Agent Plugin

## Overview

Cursor Agent Plugin provides seamless integration between the Cursor Agent and Neovim. It enables direct communication with the Cursor Agent CLI from within the editor, context-aware interactions, and various utilities to enhance AI-assisted development within Neovim.

## Project Structure

- `/lua/cursor-agent`: Main plugin code
- `/lua/cursor-agent/cli`: Cursor Agent CLI integration
- `/lua/cursor-agent/ui`: UI components for interactions
- `/lua/cursor-agent/context`: Context management utilities
- `/after/plugin`: Plugin setup and initialization
- `/doc`: Vim help documentation

## Current Focus

- Integrating nvim-toolkit for shared utilities
- Adding hooks-util as git submodule for development workflow
- Enhancing bidirectional communication with Cursor Agent CLI
- Implementing better context synchronization
- Adding buffer-specific context management

Example configuration to disable multi-instance mode:

```lua
require('cursor-agent').setup({})
```
