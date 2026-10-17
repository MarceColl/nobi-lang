import React from 'react';
import { StatusPill } from '../../components/core/StatusPill.jsx';
import { Button } from '../../components/core/Button.jsx';
import { GlowingMushroom } from '../../components/brand/GlowingMushroom.jsx';
import { TerminalDemo } from './TerminalDemo.jsx';

const ROTATING = ['grow', 'manage', 'monetize', 'scale', 'evolve'];

export function Hero({ onRequest }) {
  const [i, setI] = React.useState(0);
  const [phase, setPhase] = React.useState('visible');

  React.useEffect(() => {
    const t = setInterval(() => {
      setPhase('exiting');
      setTimeout(() => { setI(n => (n + 1) % ROTATING.length); setPhase('entering'); }, 400);
      setTimeout(() => setPhase('visible'), 450);
    }, 2800);
    return () => clearInterval(t);
  }, []);

  const gradText = {
    background: 'var(--grad-text)',
    WebkitBackgroundClip: 'text',
    backgroundClip: 'text',
    WebkitTextFillColor: 'transparent',
  };

  return (
    <section style={{ position: 'relative', padding: '64px 32px 128px', maxWidth: 'var(--measure)', margin: '0 auto' }}>
      <GlowingMushroom size="sm" style={{ position: 'absolute', left: 40, bottom: 80, opacity: 0.8, animation: 'kn-float 6s ease-in-out infinite' }} />
      <GlowingMushroom size="md" style={{ position: 'absolute', right: 60, bottom: 120, opacity: 0.7, animation: 'kn-float-reverse 5s ease-in-out infinite' }} />
      <GlowingMushroom size="sm" style={{ position: 'absolute', right: 180, top: 60, opacity: 0.5, animation: 'kn-float 7s ease-in-out infinite' }} />

      <div style={{ textAlign: 'center', position: 'relative', zIndex: 10 }}>
        <div style={{ marginBottom: 32 }}>
          <StatusPill hue="mint">Now in development</StatusPill>
        </div>

        <h1 style={{ fontSize: 'var(--text-h1)', marginBottom: 24 }}>
          Products that<br />
          <span style={{ display: 'inline-block', position: 'relative', verticalAlign: 'bottom' }}>
            <span style={{
              ...gradText,
              display: 'inline-block',
              transition: 'transform var(--dur-slow) var(--ease), opacity var(--dur-slow) var(--ease)',
              transform: phase === 'exiting' ? 'translateY(100%)' : phase === 'entering' ? 'translateY(-100%)' : 'translateY(0)',
              opacity: phase === 'visible' ? 1 : 0,
            }}>{ROTATING[i]}</span>
          </span>{' '}
          <span style={gradText}>themselves</span>
        </h1>

        <p style={{ fontSize: 'var(--text-lead)', color: 'var(--kn-text-muted)', maxWidth: 640, margin: '0 auto 40px', lineHeight: 'var(--leading-body)' }}>
          AI agents that build, manage, and monetize your product autonomously—supervised by the system, not by you. From idea to revenue, on autopilot.
        </p>

        <Button variant="primary" size="lg" onClick={onRequest}>Request access →</Button>
      </div>

      <TerminalDemo />
    </section>
  );
}
