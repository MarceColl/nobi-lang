import React from 'react';
import { Dialog } from '../../components/surfaces/Dialog.jsx';
import { Input } from '../../components/core/Input.jsx';
import { Button } from '../../components/core/Button.jsx';

export function WaitlistDialog({ open, onClose }) {
  const [email, setEmail] = React.useState('');
  const [submitted, setSubmitted] = React.useState(false);

  React.useEffect(() => { if (!open) { setSubmitted(false); setEmail(''); } }, [open]);

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Get early access"
      description="Join the waitlist to be among the first to experience products that build and run themselves."
    >
      {submitted ? (
        <div style={{
          padding: '20px 24px',
          background: 'rgba(125,211,192,0.15)',
          border: '1px solid rgba(125,211,192,0.3)',
          borderRadius: 'var(--radius-lg)',
          color: 'var(--kn-mint)',
          fontSize: 'var(--text-base)',
          textAlign: 'center',
        }}>
          You're on the list! We'll be in touch soon.
        </div>
      ) : (
        <form
          onSubmit={(e) => { e.preventDefault(); if (email) setSubmitted(true); }}
          style={{ display: 'flex', flexDirection: 'column', gap: 16 }}
        >
          <Input type="email" placeholder="Enter your email" value={email} required onChange={(e) => setEmail(e.target.value)} />
          <Button type="submit" variant="primary" square block style={{ padding: '16px 32px', fontSize: 'var(--text-base)' }}>
            Join the waitlist
          </Button>
        </form>
      )}
    </Dialog>
  );
}
