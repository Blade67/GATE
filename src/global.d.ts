declare module "*.template.txt" {
    export default string;
};

declare module "*.ne" {
    export default nearley.Grammar;
}