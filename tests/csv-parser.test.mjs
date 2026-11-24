import assert from 'node:assert/strict';
import test from 'node:test';
import { CsvParseError, parseCSV } from '../lib/csv-parser.ts';
import { hasMissingRequiredCsvValues } from '../lib/csv-validation.ts';

test('parses quoted commas, escaped quotes, and embedded newlines', () => {
  assert.deepEqual(parseCSV('name,notes\r\n"Acme, Inc.","Says ""hello""\nworld"'), {
    headers: ['name', 'notes'],
    rows: [['Acme, Inc.', 'Says "hello"\nworld']],
  });
});

test('rejects rows with unmatched quotation marks', () => {
  assert.throws(() => parseCSV('name,notes\nAlice,"missing close'), CsvParseError);
});

test('rejects import rows missing a required mapped value', () => {
  const fields = [{ key: 'name', required: true }, { key: 'short_name', required: true }];

  assert.equal(hasMissingRequiredCsvValues(fields, { name: 'Kilogram', short_name: '' }), true);
  assert.equal(hasMissingRequiredCsvValues(fields, { name: 'Kilogram', short_name: 'kg' }), false);
});
