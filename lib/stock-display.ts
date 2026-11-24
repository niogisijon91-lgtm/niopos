export function getSoftwareStockQuantity(stock: number | null | undefined): number {
  return Number(stock ?? 0);
}

export function getStockMovementDirection(
  type: string,
  previousStock: number | null,
  newStock: number | null
): 'in' | 'out' | 'other' {
  if (type === 'in' || type === 'opening') return 'in';
  if (type === 'out') return 'out';
  if (type === 'adjustment' && previousStock != null && newStock != null) {
    if (newStock > previousStock) return 'in';
    if (newStock < previousStock) return 'out';
  }
  return 'other';
}
