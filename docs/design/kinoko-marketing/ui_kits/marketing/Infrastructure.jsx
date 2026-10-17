import React from 'react';
import { FeatureCard } from '../../components/surfaces/FeatureCard.jsx';
import { SectionHead } from './SectionHead.jsx';

const TILES = [
  { variant: 'sprout', hue: '#7DD3C0', title: 'Zero-downtime deploys', description: 'Ship instantly. Old requests finish on old code, new requests go to new code.' },
  { variant: 'cap', hue: '#B8A5D9', title: 'Automatic rollbacks', description: 'Something wrong? Roll back to any previous version with one click.' },
  { variant: 'glow', hue: '#9FEDD7', title: 'Full introspection', description: 'See every error, every user session, every request. Debug with complete context.' },
  { variant: 'cluster', hue: '#F5C869', title: 'Managed storage', description: 'Built-in database with automatic backups. No configuration required.' },
  { variant: 'spore', hue: '#B8A5D9', title: 'UI included', description: 'Admin dashboard and user-facing UI components out of the box.' },
  { variant: 'glow', hue: '#F5C869', title: 'Durable workflows', description: 'Long-running processes that survive failures. Pick up exactly where you left off.', comingSoon: true },
  { variant: 'cluster', hue: '#9FEDD7', title: 'Queues', description: 'Background job processing with automatic retries and dead letter handling.', comingSoon: true },
  { variant: 'spore', hue: '#B8A5D9', title: 'Crons', description: 'Scheduled tasks that run reliably. No infrastructure to manage.', comingSoon: true },
];

export function Infrastructure() {
  return (
    <section style={{ position: 'relative', padding: '96px 32px' }}>
      <div style={{ maxWidth: 'var(--measure)', margin: '0 auto' }}>
        <SectionHead title="Fully managed infrastructure" width="550px" gap={64}>
          Focus on what you're building, not how to run it. Everything you need, out of the box.
        </SectionHead>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))', gap: 20 }}>
          {TILES.map(t => <FeatureCard key={t.title} compact {...t} />)}
        </div>
      </div>
    </section>
  );
}
