//! Shrinking over choice sequences (design §6).
//!
//! Milestone 3 — not implemented yet. Passes P1 (chunk deletion),
//! P2 (zeroing) and P3 (power-of-two decrease), with acceptance only when
//! the re-recorded consumed sequence is strictly smaller in shortlex
//! order over values, and an explicit `fixed_point` / `budget_exhausted`
//! outcome.
