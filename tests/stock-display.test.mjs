import assert from 'node:assert/strict';
import test from 'node:test';

import {
  getSoftwareStockQuantity,
  getStockMovementDirection,
} from '../lib/stock-display.ts';

test('null software stock is displayed and exported as zero', () => {
  assert.equal(getSoftwareStockQuantity(null), 0);
  assert.equal(getSoftwareStockQuantity(undefined), 0);
  assert.equal(getSoftwareStockQuantity(4), 4);
});

test('legacy stock movement types display the correct direction', () => {
  assert.equal(getStockMovementDirection('opening', 0, 5), 'in');
  assert.equal(getStockMovementDirection('adjustment', 8, 3), 'out');
  assert.equal(getStockMovementDirection('adjustment', 3, 8), 'in');
  assert.equal(getStockMovementDirection('adjustment', 3, 3), 'other');
  assert.equal(getStockMovementDirection('out', 8, 3), 'out');
});
