export function hasMissingRequiredCsvValues(
  fields: Array<{ key: string; required?: boolean }>,
  values: Record<string, string>
): boolean {
  return fields.some((field) => field.required && !values[field.key]?.trim());
}
