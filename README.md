# Ollama Control Panel for Linux

A simple bash script to manage your Ollama models with an interactive menu.

## Features

- **List Models**: View all installed models with their sizes
- **Download Models**: Pull new models from ollama.com
- **Change Context**: Create a variant of an existing model with custom context size
- **Delete Models**: Remove models you no longer need

## Usage

```bash
chmod +x ollama_control.sh
./ollama_control.sh
```

## Requirements

- Bash shell
- [Ollama](https://ollama.com/) installed and running

## Screenshot

```
=======================================================
   OLLAMA CONTROL PANEL (Server: myserver)
=======================================================
   NO   MODEL NAME                               SIZE
   ---------------------------------------------------
    1)  llama3.2:latest                          [2.0GB]
    2)  deepseek-r1:latest                       [4.7GB]
=======================================================
 [1] Download new model (Pull)
 [2] Change Context on existing (Create)
 [3] Delete a model (Remove)
 [4] Exit
-------------------------------------------------------
 Choose action (1-4):
```

## License

MIT
