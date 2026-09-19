// Serbian noun forms after a number: 1 (and 21, 31, ... but not 11) takes the
// singular, 2-4 (and 22-24, ... but not 12-14) the "few" form, everything else
// (0, 5-20, 25-30, ...) the "many" form. E.g. 1 stavka, 3 stavke, 5 stavki.
export function pluralSr(count: number, one: string, few: string, many: string) {
  const lastTwo = count % 100;
  const last = count % 10;
  if (last === 1 && lastTwo !== 11) return one;
  if (last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)) return few;
  return many;
}
