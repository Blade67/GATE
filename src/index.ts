import template from "./header.template.txt" with { type: "text" };
import pck from "../package.json" with { type: "json" };
import { parseDynamic, parseOptional } from "./transformers";
import { parseArgs } from "util";
import chalk from "chalk";
import { Glob } from "bun";
import { lstatSync } from "node:fs";

const header = template
    .replace(/%version%/, pck.version)
    .replace(/%repository%/, pck.repository.url)
    .replace(/%author%/, pck.author)
    .replace(/%year%/, new Date().getFullYear().toString());
let input, output;

try {
    const { values } = parseArgs({
        args: Bun.argv,
        options: {
            input: {
                type: 'string',
                short: 'i',
            },
            output: {
                type: 'string',
                short: 'o',
            },
        },
        strict: true,
        allowPositionals: true,
    });

    input = values.input;
    output = values.output;

    if (output && !lstatSync(output).isDirectory()) {
        console.error(chalk.red("[GATE]"), "Output should be a directory, not a file.");
        process.exit(1);
    }
    if (!input) {
        console.error(chalk.red("[GATE]"), "No input file specified.");
        process.exit(1);
    }

    input = input.replace(/\\/g, "/");

    if (output) output = output.replace(/\\/g, "/")
} catch (error) {
    console.log(chalk.red("[GATE]"), (error as { message?: string }).message);
    process.exit(1);
}

type InputFile = { path: string, content: string };
let files: Promise<InputFile>[] = [];

if (input.endsWith(".gate")) {
    let f = Bun.file(input);

    if (!f.exists()) {
        console.error(chalk.red("[GATE]"), `File "${input}" does not exist.`);
        process.exit(1);
    }

    files.push({
        //@ts-ignore this is stupid
        path: `${f.name?.replace(/\\/g, "/")}`,
        content: await f.text()
    });
} else {
    const glob = new Glob(`${input}/**/*.gate`);
    const scannedFiles = await Array.fromAsync(glob.scan({ cwd: './' }))

    if (scannedFiles.length === 0) {
        console.error(chalk.red("[GATE]"), `No files found in "${input}".`);
        process.exit(1);
    }

    files.push(...scannedFiles.map(async (f) => {
        const file = Bun.file(f);
        return {
            path: `${file.name?.replace(/\\/g, "/")}`,
            content: await file.text()
        }
    }));
}

Promise.all(files).then(async (files) => {
    for (let file of files) {
        let f = file.content.split("\r\n").map(l => l.trimEnd())
        let signalStack: Array<String> = [];
        let lastIndent = "    ";

        for (let i = 0; i < f.length; i++) {
            if (f[i].trimStart().startsWith("$$")) {
                const dyn = f[i].trimStart().slice(2);
                if (!dyn) continue;
                const dynamic = parseDynamic(dyn);
                const signal = dyn.match(/\w+/)?.[0];
                if (signal) signalStack.push(signal);
                f[i] = dynamic;
            }
            if (f[i].includes("?.")) {
                const optionalOp = parseOptional(f[i])
                // console.log("Contains \"?\":", optionalOp, f[i]);
                f[i] = optionalOp;
            }
            if (f[i].startsWith("func _ready()") && signalStack.length > 0) {
                lastIndent = f[i + 1].match(/\s+/)?.[0] ?? "    ";

                if (f[i].includes("pass")) f[i] = f[i].replace("pass", "");
                if (f[i + 1].includes("pass")) f[i + 1] = "";

                f[i] += `\n${lastIndent}` + signalStack.map(s => `on_${s}_changed.connect(\"_on_${s}_changed\");`).join("\n" + lastIndent);

                signalStack = [];
            }
        }

        file.content = f.join("\r\n");

        if (signalStack.length > 0) {
            file.content += `\n\nfunc _ready() -> void:\n${lastIndent}` + signalStack.map(s => `on_${s}_changed.connect(\"_on_${s}_changed\");`).join("\n" + lastIndent);
        }
    }
    return files;
}).then(files => {
    for (let file of files) {
        file.path = file.path.replace(".gate", ".gd")
        const fileName = file.path.split("/").pop() ?? "";

        if (input && output) {
            file.path = file.path.replace(input, output);
        }

        console.log(chalk.blue("[GATE]"), `Writing "${chalk.green(file.path)}"...`);

        let h = header.replace(/%file_name%/g, file.path.split("/").pop())

        // TODO: Fix this to account for the input/output paths as folders properly
        Bun.write(
            output + "/" + fileName.replace(".gate", ".gd"),
            `${h}\n\n${file.content}`
        );
    }

    console.log(chalk.blue("[GATE]"), `Generated ${chalk.green(files.length)} file${files.length > 1 ? "s" : ""}.`);
});



// Bun.write("./test.gd", input.join("\r\n"));