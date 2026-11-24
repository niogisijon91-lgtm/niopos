import type { Product } from '../types';

export function findPOSProductByBarcode(products: Product[], value: string): Product | undefined {
  const barcode = value.trim().toLowerCase();
  if (!barcode) return undefined;
  return products.find((item) =>
    item.barcode?.trim().toLowerCase() === barcode
    || item.sku?.trim().toLowerCase() === barcode
  );
}
