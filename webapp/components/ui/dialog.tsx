"use client"

import * as React from "react"
import * as DialogPrimitive from "@radix-ui/react-dialog"

import { cn } from "@/lib/utils"
import { OVERLAY_SCRIM_CLASS } from "@/app/components/card-surface-tokens"

const Dialog = DialogPrimitive.Root

const DialogPortal = DialogPrimitive.Portal

// Tint and blur come from the shared OVERLAY_SCRIM_CLASS so every backdrop stays consistent.
const overlayClassName = `fixed inset-0 z-50 ${OVERLAY_SCRIM_CLASS} data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0`

const DialogOverlay = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Overlay>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Overlay>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Overlay ref={ref} className={cn(overlayClassName, className)} {...props} />
))
DialogOverlay.displayName = DialogPrimitive.Overlay.displayName

type DialogContentProps = React.ComponentPropsWithoutRef<typeof DialogPrimitive.Content> & {
  fullScreenOnMobile?: boolean
  hideMobileHandle?: boolean
}

const DialogContent = React.forwardRef<React.ElementRef<typeof DialogPrimitive.Content>, DialogContentProps>(
  ({ className, children, fullScreenOnMobile = false, hideMobileHandle = false, ...props }, ref) => {
    const [dragOffset, setDragOffset] = React.useState(0)
    const [isDragging, setIsDragging] = React.useState(false)
    const contentRef = React.useRef<HTMLDivElement | null>(null)
    const closeButtonRef = React.useRef<HTMLButtonElement | null>(null)
    const dragStateRef = React.useRef<{
      pointerId: number
      startY: number
      offset: number
      contentHeight: number
      moved: boolean
    } | null>(null)

    const composedRef = React.useCallback(
      (node: HTMLDivElement | null) => {
        contentRef.current = node
        if (typeof ref === "function") {
          ref(node)
        } else if (ref) {
          ref.current = node
        }
      },
      [ref],
    )

    const endDrag = React.useCallback((shouldClose: boolean, finalOffset: number) => {
      dragStateRef.current = null
      setIsDragging(false)

      if (shouldClose) {
        setDragOffset(0)
        closeButtonRef.current?.click()
        return
      }

      setDragOffset(Math.max(0, finalOffset))
    }, [])

    const handlePointerDown = React.useCallback(
      (event: React.PointerEvent<HTMLDivElement>) => {
        if (window.innerWidth >= 640) {
          return
        }

        dragStateRef.current = {
          pointerId: event.pointerId,
          startY: event.clientY,
          offset: dragOffset,
          contentHeight: contentRef.current?.offsetHeight ?? 0,
          moved: false,
        }
        setIsDragging(true)
        event.currentTarget.setPointerCapture(event.pointerId)
        event.preventDefault()
      },
      [dragOffset],
    )

    const handlePointerMove = React.useCallback((event: React.PointerEvent<HTMLDivElement>) => {
      const dragState = dragStateRef.current
      if (!dragState || dragState.pointerId !== event.pointerId) {
        return
      }

      const nextOffset = event.clientY - dragState.startY + dragState.offset
      dragState.moved = dragState.moved || Math.abs(nextOffset) > 8
      setDragOffset(Math.min(320, Math.max(0, nextOffset)))
      event.preventDefault()
    }, [])

    const handlePointerUp = React.useCallback(
      (event: React.PointerEvent<HTMLDivElement>) => {
        const dragState = dragStateRef.current
        if (!dragState || dragState.pointerId !== event.pointerId) {
          return
        }

        event.currentTarget.releasePointerCapture(event.pointerId)
        const closeThreshold = Math.max(180, dragState.contentHeight * 0.32)
        const shouldClose = dragState.moved && dragOffset > closeThreshold
        endDrag(shouldClose, dragOffset)
        event.preventDefault()
      },
      [dragOffset, endDrag],
    )

    const handlePointerCancel = React.useCallback(
      (event: React.PointerEvent<HTMLDivElement>) => {
        const dragState = dragStateRef.current
        if (!dragState || dragState.pointerId !== event.pointerId) {
          return
        }

        endDrag(false, dragOffset)
        event.preventDefault()
      },
      [dragOffset, endDrag],
    )

    return (
      <DialogPortal>
        <DialogOverlay />
        <DialogPrimitive.Content
          ref={composedRef}
          className={cn(
            "mobile-bottom-sheet mobile-dialog-sheet fixed left-[50%] top-[50%] z-50 grid w-full max-w-lg translate-x-[-50%] translate-y-[-50%] gap-4 border-0 bg-card p-5 shadow-elev-2 duration-200 data-[state=closed]:animate-out data-[state=closed]:fade-out-0 sm:rounded-radius-lg sm:p-5 sm:data-[state=closed]:zoom-out-95 sm:data-[state=open]:zoom-in-95 sm:data-[state=closed]:slide-out-to-left-1/2 sm:data-[state=closed]:slide-out-to-top-[48%] sm:data-[state=open]:slide-in-from-left-1/2 sm:data-[state=open]:slide-in-from-top-[48%]",
            fullScreenOnMobile &&
              "mobile-bottom-sheet-fullscreen max-md:left-0 max-md:top-0 max-md:h-[100dvh] max-md:w-screen max-md:max-w-none max-md:translate-x-0 max-md:translate-y-0 max-md:rounded-none max-md:border-0 max-md:p-0 max-md:shadow-none max-md:overflow-hidden",
            isDragging ? "mobile-bottom-sheet-dragging" : "",
            className,
          )}
          style={dragOffset ? { transform: `translateY(${dragOffset}px)` } : undefined}
          {...props}
        >
          {!fullScreenOnMobile && !hideMobileHandle ? (
            <div
              className="mobile-bottom-sheet-handle absolute inset-x-0 top-0 z-10 flex h-10 items-start justify-center pt-3 sm:hidden"
              onPointerDown={handlePointerDown}
              onPointerMove={handlePointerMove}
              onPointerUp={handlePointerUp}
              onPointerCancel={handlePointerCancel}
            >
              <div className="h-1.5 w-[4.5rem] rounded-full bg-foreground/35 shadow-[0_1px_0_rgba(255,255,255,0.18)_inset]" />
            </div>
          ) : null}
          {children}
          <DialogPrimitive.Close
            ref={closeButtonRef}
            className="pointer-events-none absolute opacity-0"
            aria-hidden="true"
            tabIndex={-1}
          >
            <span className="sr-only">Close</span>
          </DialogPrimitive.Close>
        </DialogPrimitive.Content>
      </DialogPortal>
    )
  },
)
DialogContent.displayName = DialogPrimitive.Content.displayName

const DialogHeader = ({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
  <div className={cn("flex flex-col space-y-1.5 text-center sm:text-left", className)} {...props} />
)
DialogHeader.displayName = "DialogHeader"

const DialogFooter = ({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
  <div className={cn("flex flex-col-reverse sm:flex-row sm:justify-end sm:space-x-2", className)} {...props} />
)
DialogFooter.displayName = "DialogFooter"

const DialogTitle = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Title>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Title>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Title
    ref={ref}
    className={cn("text-[14px] leading-none tracking-tight text-foreground", className)}
    {...props}
  />
))
DialogTitle.displayName = DialogPrimitive.Title.displayName

const DialogDescription = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Description>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Description>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Description ref={ref} className={cn("text-[12px] text-muted-foreground", className)} {...props} />
))
DialogDescription.displayName = DialogPrimitive.Description.displayName

export { Dialog, DialogContent, DialogHeader, DialogFooter, DialogTitle, DialogDescription }
