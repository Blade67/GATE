import chalk from "chalk";

export default function parseOptional(input: string) {
    const tokens = input.match(/\w+(\?\.\w+)+/g)?.map(e => e.split("?.")).flat()
    if (!tokens) return input;

    let out = "";
    let vname = "";

    if (input.trimStart().startsWith("if")) {
        vname = "_" + tokens[tokens.length - 1]
    } else if (input.trimStart().startsWith("var")) {
        vname = "" + input.trimStart().replace("var ", "").match(/\w+/)?.[0]
    } else {
        console.error(chalk.red("[GATE]"), `Unhandled case for optional operator for line "${input}".`);
        process.exit(1);
    }

    const indent = new Array(input.match(/\s*/)?.[0]?.length ?? 0 > 0 ? 1 + (input.match(/\s*/)?.[0]?.length ?? 0) : 0).join(" ")

    out = `${indent}var ${vname} = null\n`;
    out += `${indent}if ${tokens[0]}${tokens.slice(1).map((token, idx, arr) => `${idx > 0 ? arr[idx] : ""} && ${token}`).join(' in ')} in ${tokens.slice(0, -1).join('.')}:\n`
    out += `${indent + indent}${vname} = ${tokens.join(".")}`

    return out;
}