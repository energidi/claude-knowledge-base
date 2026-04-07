/**
 * DependencyJobException
 *
 * Custom exception thrown by DependencyJobController and DependencyQueueable
 * for user-facing error conditions (concurrency rejection, permission failures,
 * storage threshold exceeded, async context guard, cancel failures).
 * Messages are surfaced directly in the LWC as toast errors or banners.
 *
 * Ref: ISP-6072
 */
public class DependencyJobException extends Exception {}
