import { describe, expect, it } from 'vitest';
import { formatCents, formatDecimal, toCents } from './money';

describe('toCents', () => {
  it('turns a DECIMAL string into integer cents', () => {
    expect(toCents('0')).toBe(0);
    expect(toCents('1')).toBe(100);
    expect(toCents('25000')).toBe(2_500_000);
    expect(toCents('25000.50')).toBe(2_500_050);
    expect(toCents('0.99')).toBe(99);
  });

  it('pads a short fraction', () => {
    // MariaDB sends "25000.5", not "25000.50", when a column is cast inside a
    // query. Both must mean 25,000.50.
    expect(toCents('25000.5')).toBe(2_500_050);
  });

  it('truncates a third decimal instead of rounding it', () => {
    // The server decides the official amount; the client must never round up
    // and show more than the actual bill.
    expect(toCents('10.999')).toBe(1099);
  });

  it('handles negative values', () => {
    // "No cheese −2,500" is a legitimate price difference on a menu option.
    expect(toCents('-2500')).toBe(-250_000);
    expect(toCents('-2.50')).toBe(-250);
    expect(toCents('-0.50')).toBe(-50);
  });

  it('returns 0 for nonsense input', () => {
    expect(toCents('')).toBe(0);
    expect(toCents('abc')).toBe(0);
    expect(toCents(null as unknown as string)).toBe(0);
    expect(toCents(undefined as unknown as string)).toBe(0);
  });

  it('loses no precision over repeated addition', () => {
    // The whole reason for integer cents: in floating point, 0.1 + 0.2 is not 0.3.
    let total = 0;
    for (let i = 0; i < 10; i++) total += toCents('0.10');
    expect(total).toBe(100);
  });
});

describe('formatCents', () => {
  it('formats as rupiah without decimals', () => {
    // Restaurant receipts in Indonesia never show fractions of a rupiah.
    const shown = formatCents(2_500_000);
    expect(shown).toContain('25.000');
    expect(shown).not.toContain(',00');
  });

  it('accepts zero', () => {
    expect(formatCents(0)).toContain('0');
  });
});

describe('formatDecimal', () => {
  it('bridges a server string straight to display', () => {
    expect(formatDecimal('25000.00')).toBe(formatCents(2_500_000));
  });
});
