/** Stripe-branded mark for the physical-card payment method selector. */
export function StripeIcon({ size = 22 }: { size?: number }) {
	return (
		<svg
			aria-hidden="true"
			width={size}
			height={size}
			viewBox="0 0 32 32"
			fill="none"
			xmlns="http://www.w3.org/2000/svg"
		>
			<rect width="32" height="32" rx="8" fill="#635BFF" />
			<path
				d="M16.3 8.1c-3.7 0-6.2 1.9-6.2 4.8 0 3.1 2.8 4.1 5.1 4.8 1.5.5 2.5.9 2.5 1.7 0 .7-.7 1.1-1.8 1.1-1.7 0-3.5-.7-4.9-1.7v3.8c1.3.8 3.1 1.3 5 1.3 3.9 0 6.5-1.9 6.5-5 0-3.1-2.7-4.1-5.1-4.8-1.5-.5-2.5-.8-2.5-1.6 0-.6.6-1 1.7-1 1.5 0 3.1.5 4.5 1.3V9.1c-1.3-.7-2.9-1-4.8-1Z"
				fill="white"
			/>
		</svg>
	)
}
