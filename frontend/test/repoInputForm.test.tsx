import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { RepoInputForm, validateBasicGitHubUrl } from '../src/components/RepoInputForm';

describe('RepoInputForm', () => {
  it('validates GitHub HTTPS URLs cleanly before dispatch', () => {
    expect(validateBasicGitHubUrl('https://github.com/octocat/Hello-World')).toBeNull();
    expect(validateBasicGitHubUrl('http://github.com/octocat/Hello-World')).not.toBeNull();
    expect(validateBasicGitHubUrl('https://user:pass@github.com/octocat/Hello-World')).not.toBeNull();
    expect(validateBasicGitHubUrl('https://github.com:8443/octocat/Hello-World')).not.toBeNull();
    expect(validateBasicGitHubUrl('https://gitlab.com/octocat/Hello-World')).not.toBeNull();
    expect(validateBasicGitHubUrl('https://github.com/octocat/Hello-World?tab=readme')).not.toBeNull();
    expect(validateBasicGitHubUrl('https://github.com/octocat/Hello-World#top')).not.toBeNull();
    expect(validateBasicGitHubUrl('https://github.com/octocat')).not.toBeNull();
  });

  it('submits valid URL, blocks invalid inputs, prevents duplicate submissions, and supports UUID lookup', async () => {
    const user = userEvent.setup();
    const onSubmitRepo = vi.fn(async () => undefined);
    const onLookupAnalysisId = vi.fn();

    const { rerender } = render(
      <RepoInputForm
        onSubmitRepo={onSubmitRepo}
        onLookupAnalysisId={onLookupAnalysisId}
        isSubmitting={false}
        hasInFlightAnalysis={false}
        submitError={null}
        sessionHistory={[]}
        activeAnalysisId={null}
      />,
    );

    const urlInput = screen.getByLabelText(/GitHub Repository HTTPS URL/i);
    await user.type(urlInput, 'http://github.com/octocat/Hello-World');
    await user.click(screen.getByRole('button', { name: /Start Analysis/i }));
    expect(screen.getByRole('alert')).toHaveTextContent(/Only https:\/\//i);
    expect(onSubmitRepo).not.toHaveBeenCalled();

    await user.clear(urlInput);
    await user.type(urlInput, 'https://github.com/octocat/Hello-World');
    await user.click(screen.getByRole('button', { name: /Start Analysis/i }));
    expect(onSubmitRepo).toHaveBeenCalledTimes(1);
    expect(onSubmitRepo).toHaveBeenCalledWith('https://github.com/octocat/Hello-World');

    // Guard against duplicate submits during active submission / in-flight analysis
    rerender(
      <RepoInputForm
        onSubmitRepo={onSubmitRepo}
        onLookupAnalysisId={onLookupAnalysisId}
        isSubmitting={false}
        hasInFlightAnalysis={true}
        submitError={null}
        sessionHistory={[]}
        activeAnalysisId="550e8400-e29b-41d4-a716-446655440000"
      />,
    );
    expect(screen.getByRole('button', { name: /Analysis In Progress/i })).toBeDisabled();

    // Analysis ID lookup
    const lookupInput = screen.getByLabelText(/Open by Analysis ID/i);
    await user.type(lookupInput, 'bad-uuid');
    await user.click(screen.getByRole('button', { name: /Load Analysis/i }));
    expect(onLookupAnalysisId).not.toHaveBeenCalled();

    await user.clear(lookupInput);
    await user.type(lookupInput, '550e8400-e29b-41d4-a716-446655440000');
    await user.click(screen.getByRole('button', { name: /Load Analysis/i }));
    expect(onLookupAnalysisId).toHaveBeenCalledWith('550e8400-e29b-41d4-a716-446655440000');
  });
});
