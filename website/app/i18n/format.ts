export function format(
  template: string,
  params: Record<string, string | number | undefined | null>
) {
  return template.replace(/\{(\w+)\}/g, (_m, key: string) => {
    const v = params[key];
    return v === undefined || v === null ? `{${key}}` : String(v);
  });
}

