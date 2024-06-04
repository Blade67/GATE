import chalk from "chalk";

// NOTE: Currently only supports variables!
export default function parseOptional(input: string) {
    if (!input.trim().startsWith("var")) {
        console.log(chalk.yellow("[GATE]"), `The optional operator is only supported for variables!`);
        return input;
    }
    const startTokens = input.slice(0, input.indexOf("=") + 1);
    const optTokens = input
        .slice(input.indexOf("=") + 1)
        .trim()
        .split(/(\?\.|\.)/)
        .filter(e => e !== "." && e !== "?.");
    if (!optTokens) return input;


    let out = ""
    let condition = "";
    for (let i = 1; i < optTokens.length; i++) {
        condition += `${optTokens[i]} in ${optTokens.slice(0, i).join(".")}`;
        if (i < optTokens.length - 1) condition += " && ";
    }

    // TODO: Account for indentation, read from editorconfig
    out += `${startTokens} null\nif ${condition}:\n    ${input.split(" ")[1]} = ${input
        .slice(input.indexOf("=") + 1)
        .split("?.")
        .join(".")
        }`;

    return out;
}