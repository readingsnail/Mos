"use client";

import { ReactNode, useCallback, useState } from "react";

async function copyToClipboard(value: string) {
  try {
    await navigator.clipboard.writeText(value);
    return true;
  } catch {
    // Fallback for older browsers / permissions.
    try {
      const el = document.createElement("textarea");
      el.value = value;
      el.setAttribute("readonly", "");
      el.style.position = "fixed";
      el.style.top = "-9999px";
      document.body.appendChild(el);
      el.select();
      const ok = document.execCommand("copy");
      document.body.removeChild(el);
      return ok;
    } catch {
      return false;
    }
  }
}

export function CopyButton({
  value,
  children,
  className = "",
  copiedLabel = "Copied",
}: {
  value: string;
  children: ReactNode;
  className?: string;
  copiedLabel?: string;
}) {
  const [copied, setCopied] = useState(false);

  const onCopy = useCallback(async () => {
    const ok = await copyToClipboard(value);
    if (!ok) return;
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1400);
  }, [value]);

  return (
    <button type="button" onClick={onCopy} className={className}>
      {copied ? copiedLabel : children}
    </button>
  );
}

