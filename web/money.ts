/**
 * Money is always handled as integer cents, never as a floating-point decimal.
 *
 * The server computes every official total (in MariaDB, with DECIMAL), and
 * these numbers are only for display. They are still exact, so that the
 * guest's screen and the printed receipt never differ by a single rupiah.
 * The API sends DECIMAL columns as strings ("25000.50"), never as JSON numbers.
 */
export function toCents(decimalString: string): number {
  const [whole, frac = '0'] = (decimalString ?? '0').split('.');
  const negative = whole.trimStart().startsWith('-');
  const magnitude = Math.abs(Number(whole)) * 100 + Number(frac.padEnd(2, '0').slice(0, 2));
  const cents = negative ? -magnitude : magnitude;
  return Number.isFinite(cents) ? cents : 0;
}

const idr = new Intl.NumberFormat('id-ID', {
  style: 'currency',
  currency: 'IDR',
  minimumFractionDigits: 0,
  maximumFractionDigits: 0,
});

export function formatCents(cents: number): string {
  return idr.format(Math.round(cents / 100));
}

export function formatDecimal(decimalString: string): string {
  return formatCents(toCents(decimalString));
}
