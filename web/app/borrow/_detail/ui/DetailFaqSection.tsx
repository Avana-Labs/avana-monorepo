"use client"

import * as React from "react"
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion"
import { cn } from "@/lib/utils"

export type DetailFaqItem = {
  question: string
  answer: React.ReactNode
}

type DetailFaqSectionProps = {
  title: React.ReactNode
  items: DetailFaqItem[]
  className?: string
  id?: string
}

export function DetailFaqSection({ title, items, className, id }: DetailFaqSectionProps) {
  if (items.length === 0) return null

  return (
    <section id={id} className={cn("min-w-0 space-y-2.5", className)}>
      <h2 className="text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
        {title}
      </h2>

      <Accordion type="single" collapsible className="w-full">
        {items.map((item, index) => (
          <AccordionItem
            key={item.question}
            value={`faq-${index}`}
            className={cn(
              // AccordionItem defaults to border-b; keep separators between items only so
              // this section doesn't double-up with detail page section dividers.
              "border-b-0",
              index > 0 && "border-t border-border/70 dark:border-white/10",
            )}
          >
            <AccordionTrigger className="py-4 text-left text-[16px] font-normal tracking-[-0.02em] text-muted-foreground transition-colors hover:text-foreground data-[state=open]:text-foreground md:py-[18px]">
              <span className="max-w-[calc(100%-20px)]">{item.question}</span>
            </AccordionTrigger>
            <AccordionContent className="pb-5 text-[15px] leading-[1.6] text-muted-foreground dark:text-white/68 md:text-[16px]">
              {item.answer}
            </AccordionContent>
          </AccordionItem>
        ))}
      </Accordion>
    </section>
  )
}
