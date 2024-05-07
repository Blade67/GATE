// FIXME: Remove, debug purposes only
const inputFile = await Bun.file("./test/input.gate").text()

type Token = {
    value: string;
    type: string;
    children: Token[];
    indent: number;
}

const tokenables = lex(inputFile)
console.log("tokenables = ", tokenables);
const tokens = tokenize(tokenables)
console.log("tokens = ", tokens);
const AST = toAST(tokens);


function lex(input: string): string[] {
    return input
        .split(/(\w*)/)
        .filter(n => n)
        .reduce((acc, i, idx, a) => (a[idx - 1] === i || idx === 0) ? acc + i : acc + "|" + i, "")
        .split("|")
        .reduce((acc: string[], curr: string) => {
            acc[acc.length] = (curr === "\n" && acc.length > 0 && acc[acc.length - 1] === "\r") ? "\r\n" : curr;
            return acc;
        }, [])
        .filter(e => e !== "\r")
}

function tokenize(input: string[]): Token[] {
    let tokens: Token[] = []
    let indent = 0
    for (let i = 0; i < input.length; i++) {
        if (i > 0 && input[i - 1] === "\r\n") {
            if (!!input[i].match(/[ \t]+/)) {
                // Get indentation depth
                indent = input[i].length;
                continue;
            } else {
                // Reset indentation depth
                indent = 0;
            }
        }
        if (!!input[i].match(/\s+/)) {
            // Remove unnecessary spaces
            continue;
        }
        if (input[i - 1] === "$$") {
            // Dynamic operator
            tokens[tokens.length - 1].type = "DYN_OP"
            tokens[tokens.length - 1].children = [...tokens[tokens.length - 1].children, {
                value: `${input[i]}`,
                type: "DYN_VAL",
                children: [],
                indent
            }]
            continue;
        }
        tokens.push({
            value: input[i],
            type: "",
            children: [],
            indent
        })
    }
    return tokens
}

function toAST(input: Token[]) {

}