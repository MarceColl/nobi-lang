import React from 'react';
import { Button } from '../../components/core/Button.jsx';
import { GlowingMushroom } from '../../components/brand/GlowingMushroom.jsx';
import { Wordmark } from '../../components/brand/Wordmark.jsx';

export function Closing({ onRequest }) {
  return (
    <section style={{ position: 'relative', padding: '96px 32px' }}>
      <div style={{ maxWidth: 'var(--measure-narrow)', margin: '0 auto' }}>
        <div style={{
          position: 'relative', overflow: 'hidden', textAlign: 'center',
          borderRadius: 'var(--radius-2xl)',
          padding: 'clamp(48px, 8vw, 64px)',
          background: 'var(--grad-cta-panel)',
          border: '1px solid rgba(139,123,181,0.2)',
        }}>
          <div style={{ position: 'absolute', top: -50, left: '50%', transform: 'translateX(-50%)', width: 400, height: 150, background: 'radial-gradient(ellipse, rgba(139,123,181,0.4) 0%, transparent 70%)', filter: 'blur(40px)', pointerEvents: 'none' }} />
          <div style={{ position: 'absolute', bottom: -30, left: '25%', width: 300, height: 100, background: 'radial-gradient(ellipse, rgba(125,211,192,0.3) 0%, transparent 70%)', filter: 'blur(40px)', pointerEvents: 'none' }} />
          <GlowingMushroom size="lg" style={{ position: 'absolute', left: -20, bottom: -20, opacity: 0.5, animation: 'kn-float 8s ease-in-out infinite' }} />
          <GlowingMushroom size="md" style={{ position: 'absolute', right: -10, top: -10, opacity: 0.4, transform: 'rotate(15deg)', animation: 'kn-float-reverse 6s ease-in-out infinite' }} />

          <h2 style={{ fontSize: 'var(--text-h3)', marginBottom: 16, position: 'relative', zIndex: 10 }}>
            Ready to let your product grow?
          </h2>
          <p style={{ fontSize: 'var(--text-section-lead)', color: 'var(--kn-text-muted)', marginBottom: 32, position: 'relative', zIndex: 10 }}>
            Join the waitlist for early access to products that build and run themselves.
          </p>
          <div style={{ position: 'relative', zIndex: 10 }}>
            <Button variant="primary" size="lg" onClick={onRequest} style={{ boxShadow: 'var(--glow-mint-strong)' }}>
              Request early access
            </Button>
          </div>
        </div>
      </div>
    </section>
  );
}

export function Footer() {
  return (
    <footer style={{ padding: '48px 32px', borderTop: '1px solid rgba(26,23,37,0.8)' }}>
      <div style={{ maxWidth: 'var(--measure)', margin: '0 auto', display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 24 }}>
        <Wordmark size={20} />
        <div style={{ display: 'flex', alignItems: 'center', gap: 32 }}>
          <a href="https://github.com/kinoko-sh/" style={{ fontSize: 'var(--text-ui)', color: 'var(--kn-text-dim)' }}>GitHub</a>
          <a href="https://discord.gg/K4NtAVcrFd" style={{ fontSize: 'var(--text-ui)', color: 'var(--kn-text-dim)' }}>Discord</a>
        </div>
      </div>
    </footer>
  );
}
window.Footer = Footer;
