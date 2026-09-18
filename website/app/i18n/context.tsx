"use client";

import { createContext, useContext, useEffect, useMemo, useRef, useState } from "react";

import { de } from "./de";
import { el } from "./el";
import { en } from "./en";
import { id } from "./id";
import { ja } from "./ja";
import { ko } from "./ko";
import { pl } from "./pl";
import { ru } from "./ru";
import { tr } from "./tr";
import { uk } from "./uk";
import { zh } from "./zh";
import { zhHant } from "./zh-Hant";

export type Language =
  | "en"
  | "zh"
  | "zh-Hant"
  | "ja"
  | "ko"
  | "ru"
  | "de"
  | "pl"
  | "el"
  | "tr"
  | "uk"
  | "id";

export type Translations = typeof en;

const SUPPORTED_LANGUAGES: readonly Language[] = [
  "en",
  "zh",
  "zh-Hant",
  "ja",
  "ko",
  "ru",
  "de",
  "pl",
  "el",
  "tr",
  "uk",
  "id",
];

function isLanguage(value: string): value is Language {
  return (SUPPORTED_LANGUAGES as readonly string[]).includes(value);
}

function uniqStrings(items: string[]) {
  return Array.from(new Set(items.filter(Boolean)));
}

function mapBrowserLanguageToSupported(langRaw: string): Language | null {
  const lang = langRaw.trim().toLowerCase();
  if (!lang) return null;

  // Chinese needs special handling for script/region.
  if (lang === "zh" || lang.startsWith("zh-") || lang.startsWith("zh_")) {
    const l = lang.replace("_", "-");
    const isHant =
      l.includes("hant") ||
      l.startsWith("zh-hk") ||
      l.startsWith("zh-tw") ||
      l.startsWith("zh-mo");
    return isHant ? "zh-Hant" : "zh";
  }

  const primary = lang.split(/[-_]/)[0] ?? "";
  if (primary === "in") return "id"; // old Indonesian code

  const asLanguage = primary as Language;
  return SUPPORTED_LANGUAGES.includes(asLanguage) ? asLanguage : null;
}

function defaultLanguageFromBrowser(): Language {
  const candidates =
    typeof navigator !== "undefined"
      ? uniqStrings([...(navigator.languages ?? []), navigator.language ?? ""])
      : [];

  for (const lang of candidates) {
    const mapped = mapBrowserLanguageToSupported(lang);
    if (mapped) return mapped;
  }

  return "en";
}

const TRANSLATIONS_BY_LANGUAGE: Record<Language, Translations> = {
  en,
  zh,
  "zh-Hant": zhHant,
  ja,
  ko,
  ru,
  de,
  pl,
  el,
  tr,
  uk,
  id,
};

interface I18nContextType {
  language: Language;
  t: Translations;
  setLanguage: (lang: Language) => void;
}

const I18nContext = createContext<I18nContextType | null>(null);

export function I18nProvider({ children }: { children: React.ReactNode }) {
  const [language, setLanguage] = useState<Language>("en");
  const didMountRef = useRef(false);

  const translations = useMemo(() => {
    return TRANSLATIONS_BY_LANGUAGE[language] ?? en;
  }, [language]);

  useEffect(() => {
    const stored = localStorage.getItem("language");
    const desiredLanguage = stored && isLanguage(stored) ? stored : defaultLanguageFromBrowser();

    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLanguage(desiredLanguage);

    try {
      localStorage.setItem("language", desiredLanguage);
    } catch {
      // ignore
    }
    try {
      document.documentElement.lang = desiredLanguage;
    } catch {
      // ignore
    }
  }, []);

  useEffect(() => {
    if (!didMountRef.current) {
      didMountRef.current = true;
      return;
    }

    try {
      localStorage.setItem("language", language);
    } catch {
      // ignore
    }
    try {
      document.documentElement.lang = language;
    } catch {
      // ignore
    }
  }, [language]);

  return (
    <I18nContext.Provider value={{ language, t: translations, setLanguage }}>
      {children}
    </I18nContext.Provider>
  );
}

export function useI18n() {
  const context = useContext(I18nContext);
  if (!context) {
    throw new Error("useI18n must be used within an I18nProvider");
  }
  return context;
}
