import React from 'react';

export function Card({ tone = 'default', padding = 24, children, style, ...rest }) {
  const tones = {
    default: {
      background: 'rgba(139, 123, 181, 0.06)',
      border: '1px solid rgba(139, 123, 181, 0.12)',
      borderRadius: 'var(--radius-lg)',
    },
    lifted: {
      background: 'var(--grad-card)',
      border: '1px solid var(--kn-border-violet)',
      borderRadius: 'var(--radius-xl)',
    },
    muted: {
      background: 'rgba(139, 123, 181, 0.04)',
      border: '1px solid rgba(139, 123, 181, 0.08)',
      borderRadius: 'var(--radius-lg)',
      opacity: 0.75,
    },
    panel: {
      background: 'var(--kn-surface)',
      border: '1px solid var(--kn-border)',
      borderRadius: 'var(--radius-xl)',
      boxShadow: 'var(--glow-violet)',
    },
  };
  return (
    <div style={{ padding, position: 'relative', ...tones[tone], ...style }} {...rest}>
      {children}
    </div>
  );
}
