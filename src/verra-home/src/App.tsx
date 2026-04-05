import { BrowserRouter, Route, Routes } from 'react-router-dom'
import { ForBusiness } from './pages/ForBusiness'
import { Home } from './pages/Home'
import { Impact } from './pages/Impact'
import { Contact } from './pages/Contact'
import { PrivacyPolicy } from './pages/PrivacyPolicy'
import { TermsOfService } from './pages/TermsOfService'
import { TheLocal } from './pages/TheLocal'

function App() {
	return (
		<BrowserRouter>
			<Routes>
				<Route path="/" element={<Home />} />
				<Route path="/local" element={<TheLocal />} />
				<Route path="/business" element={<ForBusiness />} />
				<Route path="/impact" element={<Impact />} />
				<Route path="/terms" element={<TermsOfService />} />
				<Route path="/privacy" element={<PrivacyPolicy />} />
				<Route path="/contact" element={<Contact />} />
			</Routes>
		</BrowserRouter>
	)
}

export default App
