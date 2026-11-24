export class CsvParseError extends Error {
  constructor() {
    super('Malformed CSV quoting');
    this.name = 'CsvParseError';
  }
}

export function parseCSV(text: string): { headers: string[]; rows: string[][] } {
  const cleaned = text.replace(/^\uFEFF/, '');
  const records: string[][] = [];
  let record: string[] = [];
  let field = '';
  let inQuotes = false;
  let afterQuote = false;

  for (let i = 0; i < cleaned.length; i++) {
    const ch = cleaned[i];
    if (inQuotes) {
      if (ch === '"' && cleaned[i + 1] === '"') {
        field += '"';
        i++;
      } else if (ch === '"') {
        inQuotes = false;
        afterQuote = true;
      } else {
        field += ch;
      }
      continue;
    }

    if (afterQuote) {
      if (ch === ',' || ch === '\n' || ch === '\r') {
        afterQuote = false;
      } else if (/\s/.test(ch)) {
        continue;
      } else {
        throw new CsvParseError();
      }
    }

    if (ch === '"') {
      if (field.trim()) throw new CsvParseError();
      field = '';
      inQuotes = true;
    } else if (ch === ',') {
      record.push(field.trim());
      field = '';
    } else if (ch === '\n' || ch === '\r') {
      record.push(field.trim());
      if (ch === '\r' && cleaned[i + 1] === '\n') i++;
      if (record.length > 1 || record[0]) records.push(record);
      record = [];
      field = '';
    } else {
      field += ch;
    }
  }
  if (inQuotes) throw new CsvParseError();
  if (record.length > 0 || field.trim() || afterQuote) {
    record.push(field.trim());
    if (record.length > 1 || record[0]) records.push(record);
  }

  if (records.length === 0) return { headers: [], rows: [] };
  const [headers, ...rows] = records;
  return { headers, rows };
}
