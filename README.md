# GATE
###### ⚠ **Warning**! GATE is currently undergoing heavy development and is not yet production-ready! An engine integration will soon follow.
GATE is a [GDScript](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html) superset for the [Godot Engine](https://godotengine.org/) that adds [extra features](#features) while compiling down to native GDScript.

## Table of Content
- [Usage](#usage)
- [Features](#features)
   * [Dynamic Variable Decorator `$$`](#dynamic-variable-decorator-)
   * [Optional Operator `?.`](#optional-operator)
- [Upcoming features](#upcoming-features)
- [Contributint](#contributing)

## Usage
```sh
# --input, -i
#    Path to the input `.gate` file/directory.
#    Note: Only `.gate` files are read.
#
# --output, -i
#    Path to the output directory.
#    Note: The output directory respects the input layout.

./gate --input ./path/to/myFile.gate --output ./output
```

## Features
### Dynamic Variable Decorator `$$`
The `$$` decorator automates signal, setter, getter, and connection creation.
##### Example
```gdscript
class_name Test extends Label

$$count = 0

func _ready() -> void:
    count += 1

func count_changed(value: int) -> void:
  text = "Count is %s" % value
```

### Optional Operator `?.`
The `?.` (optional) operator allows you to check for null in a chain of properties.
##### Example
```gdscript
func _ready() -> void:
    # In this case `text` is either `null` or the
    # expected value of `myProp`
    var text = $MyNode?.myObject?.myProp
```

## Upcoming features
-   [ ] Loop ranges `2..15`
    - `for i in 2..15:`
-   [ ] Spread operator `...`
    - `var arr = [0, 1, 2]`<br>`var numbers = [...arr, 3, 4, 5]`
-   [ ] Rest operator `...`
    - `myFunction(a, b, c, d, e)`<br>`func myFunction(first, second, ...rest)`
-   [ ] Destructuring `[_, _]`
    - `var [parm1, param2] = myFunction()`
-   [ ] Inline templates
    - <code>var x = \`${player1} killed ${player2}`</code>
-   [x] Optional chaining `?.`
    - `var x = $node.?thing.?deeper1.?deeper2`

## Contributing
###### GATE is made using [Bun](https://bun.sh/) with [TypeScript](https://www.typescriptlang.org/).

To install dependencies:

```bash
bun install
```

To run:

```bash
bun run dev
```

To build:
```bash
bun run build
# or
bun run build:win
bun run build:linux
bun run build:mac
```
