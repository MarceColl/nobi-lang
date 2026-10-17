import React from 'react';
import { Wordmark } from '../../components/brand/Wordmark.jsx';
import { Button } from '../../components/core/Button.jsx';

export function Nav({ onRequest }) {
  return (
    <nav style={{
      position: 'relative', zIndex: 10,
      padding: '24px 32px',
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      maxWidth: 'var(--measure)', margin: '0 auto',
    }}>
      <Wordmark size={28} />
      <Button variant="nav" onClick={onRequest}>Get early access</Button>
    </nav>
  );
}
