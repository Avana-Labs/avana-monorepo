import { type ClassValue, clsx } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

/**
 * This function takes a number and returns a formatted string representation of that number.
 * It uses the Intl.NumberFormat API to format the number according to the user's locale.
 * @param number - The number to format.
 * @returns A formatted string representation of the number.
 */
export const formatNumber = (number: number): string => {
  return Intl.NumberFormat().format(number)
}
