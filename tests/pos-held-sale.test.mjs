import assert from 'node:assert/strict';
import test from 'node:test';

const customer = { id: 'customer-1', name: 'Test Customer', phone: '5551234' };
const localStorageValues = new Map();
const localStorage = {
  getItem: (key) => localStorageValues.get(key) ?? null,
  setItem: (key, value) => localStorageValues.set(key, value),
  removeItem: (key) => localStorageValues.delete(key),
};
globalThis.window = { localStorage };
const { calcLineDiscount, calcLineTotal, usePOSStore } = await import('../store/pos-store.ts');
const { findPOSProductByBarcode } = await import('../lib/pos-barcode.ts');

test('restores a multi-product held sale without changing quantities, prices, discounts, or totals', () => {
  const cart = [
    {
      product_id: 'pen-1',
      name: 'Pen',
      sku: 'PEN-1',
      price: 2,
      quantity: 5,
      stock: 20,
      image_url: null,
      discount_type: 'percentage',
      discount_value: 12.5,
    },
    {
      product_id: 'book-1',
      name: 'Book',
      sku: 'BOOK-1',
      price: 10,
      quantity: 2,
      stock: 10,
      image_url: null,
      discount_type: 'fixed',
      discount_value: 1.25,
    },
  ];

  usePOSStore.getState().restoreHeldSale({
    cart: [{
      product_id: 'stale-item',
      name: 'Stale item',
      price: 99,
      quantity: 1,
      stock: 2,
      discount_type: 'fixed',
      discount_value: 3,
    }],
    customer: null,
    discount: 0,
    paymentMethod: 'cash',
    paidAmount: 0,
    offerId: null,
  });
  usePOSStore.getState().restoreHeldSale({
    cart,
    customer,
    discount: 4,
    paymentMethod: 'mobile',
    paidAmount: 20,
    offerId: 'offer-1',
  });

  const state = usePOSStore.getState();
  assert.deepEqual(state.cart, cart);
  assert.equal(state.getSubtotal(), 30);
  assert.equal(calcLineDiscount(state.cart[0]), 1.25);
  assert.equal(calcLineDiscount(state.cart[1]), 2.5);
  assert.equal(calcLineTotal(state.cart[0]), 8.75);
  assert.equal(calcLineTotal(state.cart[1]), 17.5);
  assert.equal(state.getItemDiscounts(), 3.75);
  assert.equal(state.getTax(), 1.31);
  assert.equal(state.getTotal(), 27.56);
  assert.equal(state.discount, 4);
  assert.equal(state.selectedCustomer, customer);
  assert.equal(state.selectedCustomerId, customer.id);
  assert.equal(state.paymentMethod, 'mobile');
  assert.equal(state.paidAmount, 20);
  assert.equal(state.selectedOfferId, 'offer-1');
});

test('restores a single held item instead of incrementing it in the current cart', () => {
  const cart = [{
    product_id: 'pen-1',
    name: 'Pen',
    price: 2,
    quantity: 5,
    stock: 20,
    discount_type: 'fixed',
    discount_value: 0.5,
  }];

  usePOSStore.getState().restoreHeldSale({
    cart,
    customer: null,
    discount: 0,
    paymentMethod: 'cash',
    paidAmount: 0,
    offerId: null,
  });

  const state = usePOSStore.getState();
  assert.deepEqual(state.cart, cart);
  assert.equal(state.cart.length, 1);
  assert.equal(state.cart[0].quantity, 5);
  assert.equal(calcLineDiscount(state.cart[0]), 2.5);
  assert.equal(state.getSubtotal(), 10);
});

test('finds a scanned barcode or SKU and adds exactly one matching product to the cart', () => {
  const product = {
    id: 'coffee-1',
    name: 'Coffee',
    sku: 'COF-1',
    barcode: 'AbC123',
    selling_price: 8,
    discount_price: null,
    stock: 10,
    image_url: null,
  };

  assert.equal(findPOSProductByBarcode([product], ' abc123 '), product);
  assert.equal(findPOSProductByBarcode([product], ' cof-1 '), product);

  usePOSStore.getState().clearCart();
  const match = findPOSProductByBarcode([product], 'ABC123');
  usePOSStore.getState().addToCart(match);

  const state = usePOSStore.getState();
  assert.equal(state.cart.length, 1);
  assert.equal(state.cart[0].product_id, product.id);
  assert.equal(state.cart[0].quantity, 1);
});
