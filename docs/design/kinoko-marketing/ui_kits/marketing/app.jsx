import React from 'react';
import { createRoot } from 'react-dom/client';
import { Ambient } from './Ambient.jsx';
import { Nav } from './Nav.jsx';
import { Hero } from './Hero.jsx';
import { Features } from './Features.jsx';
import { Collaboration } from './Collaboration.jsx';
import { Infrastructure } from './Infrastructure.jsx';
import { Closing, Footer } from './Closing.jsx';
import { WaitlistDialog } from './WaitlistDialog.jsx';

function Site() {
  const [modal, setModal] = React.useState(false);
  const open = () => setModal(true);
  return (
    <div style={{ minHeight: '100vh', position: 'relative', overflow: 'hidden', background: 'var(--kn-void)' }}>
      <Ambient />
      <Nav onRequest={open} />
      <Hero onRequest={open} />
      <Features />
      <Collaboration />
      <Infrastructure />
      <Closing onRequest={open} />
      <Footer />
      <WaitlistDialog open={modal} onClose={() => setModal(false)} />
    </div>
  );
}

createRoot(document.getElementById('root')).render(<Site />);
