/**
 * In-memory sliding-window rate limiter. One instance per rule. State is lost on restart,
 * which is acceptable for a single-container service: limits are abuse brakes, not quotas.
 */
export class SlidingWindowLimiter {
  private readonly hits = new Map<string, number[]>();
  private lastSweep = 0;

  constructor(
    readonly limit: number,
    readonly windowMs: number,
    private readonly clock: () => number = Date.now,
  ) {}

  /**
   * Records a hit for `key` if it is allowed. Returns the number of seconds to wait when the
   * limit is reached, or 0 when the hit was accepted. A limit of 0 disables the rule.
   */
  take(key: string): number {
    if (this.limit <= 0) return 0;
    const t = this.clock();
    this.sweep(t);
    const from = t - this.windowMs;
    const list = (this.hits.get(key) ?? []).filter((h) => h > from);
    if (list.length >= this.limit) {
      this.hits.set(key, list);
      const oldest = list[0] ?? t;
      return Math.max(1, Math.ceil((oldest + this.windowMs - t) / 1000));
    }
    list.push(t);
    this.hits.set(key, list);
    return 0;
  }

  /** Checks without recording. */
  peek(key: string): number {
    if (this.limit <= 0) return 0;
    const t = this.clock();
    const list = (this.hits.get(key) ?? []).filter((h) => h > t - this.windowMs);
    if (list.length < this.limit) return 0;
    return Math.max(1, Math.ceil(((list[0] ?? t) + this.windowMs - t) / 1000));
  }

  private sweep(t: number): void {
    if (t - this.lastSweep < 60_000) return;
    this.lastSweep = t;
    const from = t - this.windowMs;
    for (const [k, list] of this.hits) {
      if (!list.some((h) => h > from)) this.hits.delete(k);
    }
  }
}
