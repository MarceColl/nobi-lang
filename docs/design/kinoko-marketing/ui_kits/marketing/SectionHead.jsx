import React from 'react';

/* The centered heading + lead, repeated three times in App.tsx.
   The source uses marginBottom 48 in two sections and 64 in the other two. */
export function SectionHead({ title, children, width = 'var(--measure-copy)', gap = 48 }) {
  return (
    <div style={{ textAlign: 'center', marginBottom: gap }}>
      <h2 style={{ fontSize: 'var(--text-h2)', marginBottom: 16 }}>{title}</h2>
      {children && (
        <p style={{ fontSize: 'var(--text-section-lead)', color: 'var(--kn-text-muted)', maxWidth: width, margin: '0 auto', lineHeight: 'var(--leading-body)' }}>
          {children}
        </p>
      )}
    </div>
  );
}
