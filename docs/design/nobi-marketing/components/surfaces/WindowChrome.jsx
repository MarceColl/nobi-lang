import React from 'react';

export function WindowChrome({ title, right, dense = false, children, style, ...rest }) {
  return (
    <div
      style={{
        background: 'var(--kn-surface)',
        border: '1px solid var(--kn-border)',
        borderRadius: 'var(--radius-xl)',
        overflow: 'hidden',
        boxShadow: 'var(--glow-violet)',
        ...style,
      }}
      {...rest}
    >
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--space-2)',
          padding: dense ? '12px 16px' : '16px 24px',
          borderBottom: '1px solid var(--kn-border)',
          background: dense ? 'rgba(26, 23, 37, 0.5)' : 'transparent',
        }}
      >
        <span style={{ width: 12, height: 12, borderRadius: '50%', background: 'var(--kn-red)', opacity: 0.8 }} />
        <span style={{ width: 12, height: 12, borderRadius: '50%', background: 'var(--kn-amber)', opacity: 0.8 }} />
        <span style={{ width: 12, height: 12, borderRadius: '50%', background: 'var(--kn-mint)', opacity: 0.8 }} />
        {title && (
          <span style={{ marginLeft: dense ? 12 : 16, fontSize: dense ? 'var(--text-code)' : 'var(--text-ui)', color: 'var(--kn-text-dim)' }}>
            {title}
          </span>
        )}
        {right && <div style={{ marginLeft: 'auto', display: 'flex', gap: 'var(--space-4)', fontSize: 'var(--text-xs)' }}>{right}</div>}
      </div>
      {children}
    </div>
  );
}
