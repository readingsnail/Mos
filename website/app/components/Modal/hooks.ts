"use client";

import { useCallback, useState } from "react";

export function useModal(initialOpen = false) {
  const [isOpen, setIsOpen] = useState(initialOpen);
  const handleOpen = useCallback(() => setIsOpen(true), []);
  const handleClose = useCallback(() => setIsOpen(false), []);
  return { isOpen, handleOpen, handleClose, setIsOpen };
}

