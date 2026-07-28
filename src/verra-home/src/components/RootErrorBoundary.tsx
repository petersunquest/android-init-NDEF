import { Component, type ErrorInfo, type ReactNode } from 'react'

type Props = { children: ReactNode }

type State = { error: Error | null }

/**
 * In-app browsers (e.g. Base) may throw during render; without a boundary the shell stays blank.
 */
export class RootErrorBoundary extends Component<Props, State> {
	state: State = { error: null }

	static getDerivedStateFromError(error: Error): State {
		return { error }
	}

	override componentDidCatch(error: Error, info: ErrorInfo): void {
		console.error('[verra-home] RootErrorBoundary', error, info.componentStack)
	}

	override render(): ReactNode {
		if (this.state.error) {
			return (
				<div
					style={{
						minHeight: '100vh',
						padding: '24px 16px',
						background: '#f9f9fe',
						color: '#1a1c1f',
						fontFamily: 'system-ui, -apple-system, sans-serif',
					}}
				>
					<h1 style={{ fontSize: '18px', fontWeight: 700, margin: 0 }}>Something went wrong</h1>
					<p style={{ marginTop: '8px', fontSize: '14px', opacity: 0.9 }}>
						Please open this page in Safari or Chrome, or try another wallet browser.
					</p>
					<pre
						style={{
							marginTop: '16px',
							padding: '12px',
							borderRadius: '8px',
							fontSize: '12px',
							background: '#ededf2',
							whiteSpace: 'pre-wrap',
							wordBreak: 'break-word',
							overflow: 'auto',
						}}
					>
						{this.state.error.message}
					</pre>
				</div>
			)
		}
		return this.props.children
	}
}
