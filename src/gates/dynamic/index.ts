import template from "./dynamic.template.txt" with { type: "text" };

export default function parseDynamic(input: string) {
    let tokens = tokenizeDynamic(input);

    input = template
        .replace(/%label%/g, tokens.label)
        .replace(/%opt_type%/g, tokens.type ? `: ${tokens.type}` : "")
        .replace(/%value%/g, tokens.value);

    return input;
}

function tokenizeDynamic(input: string): { label: string, type: string | null, value: string } {
    let label = "" + input.match(/\w+/);

    input = input.replace(label, "");

    let type =
        input.trim().startsWith(":") && !input.trim().startsWith(":=")
            ? "" + input.match(/\w+/)
            : null;
    let value = input
        .replace(type ?? "", "")
        .replace(":", "")
        .replace("=", "")
        .trimStart();

    // TODO: Refactor
    if (!type) {
        if (
            value.startsWith("\"") ||
            value.startsWith("\"\"\"") ||
            value.startsWith("\`")
        ) {
            type = "string";
        } else if (!isNaN(Number(value))) {
            if (value.includes(".")) {
                type = "float";
            } else {
                type = "int";
            }
        } else if (value === "true" || value === "false") {
            type = "bool";
        }
    }

    return {
        label,
        type,
        value
    };
}