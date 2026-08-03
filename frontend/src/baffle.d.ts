declare module "baffle" {
  interface BaffleOptions {
    characters?: string;
    exclude?: string[];
    speed?: number;
  }
  interface BaffleInstance {
    start(): BaffleInstance;
    stop(): BaffleInstance;
    once(): BaffleInstance;
    reveal(duration?: number, delay?: number): BaffleInstance;
    set(opts: BaffleOptions): BaffleInstance;
    text(fn: (current: string) => string): BaffleInstance;
  }
  function baffle(
    elements: string | Element | Element[] | NodeList,
    options?: BaffleOptions,
  ): BaffleInstance;
  export default baffle;
}
