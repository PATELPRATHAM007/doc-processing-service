/**
 * DocuExtract — Asynchronous Document Processing Frontend
 * Handles drag-and-drop upload, client validation, async task polling,
 * result viewing, clipboard copy, and state transitions.
 */

(function () {
  'use strict';

  // Configuration aligned with backend settings
  const CONFIG = {
    UPLOAD_ENDPOINT: '/api/v1/documents',
    JOB_STATUS_ENDPOINT: (id) => `/api/v1/jobs/${encodeURIComponent(id)}`,
    JOB_RESULT_ENDPOINT: (id) => `/api/v1/jobs/${encodeURIComponent(id)}/result`,
    MAX_FILE_SIZE_BYTES: 10 * 1024 * 1024, // 10 MB
    ALLOWED_EXTENSIONS: ['pdf', 'png', 'jpg', 'jpeg', 'webp', 'tiff', 'bmp'],
    ALLOWED_MIME_TYPES: [
      'application/pdf',
      'image/png',
      'image/jpeg',
      'image/webp',
      'image/tiff',
      'image/bmp',
    ],
    POLL_INTERVAL_MS: 1500,
    MAX_POLL_ATTEMPTS: null, // No timeout limit — poll until job completed or failed
  };

  // State
  const state = {
    selectedFile: null,
    currentJobId: null,
    currentDocumentId: null,
    pollTimer: null,
    pollAttempts: 0,
    elapsedTimer: null,
    elapsedSeconds: 0,
    extractedRawText: '',
  };

  // DOM Elements cache
  let el = {};

  document.addEventListener('DOMContentLoaded', () => {
    cacheElements();
    bindEvents();
  });

  function cacheElements() {
    el = {
      // Containers
      uploadSection: document.getElementById('uploadSection'),
      processingSection: document.getElementById('processingSection'),
      resultSection: document.getElementById('resultSection'),
      errorAlert: document.getElementById('errorAlert'),
      errorAlertTitle: document.getElementById('errorAlertTitle'),
      errorAlertMessage: document.getElementById('errorAlertMessage'),
      btnCloseAlert: document.getElementById('btnCloseAlert'),

      // Upload controls
      dropZone: document.getElementById('dropZone'),
      fileInput: document.getElementById('fileInput'),
      selectedFileCard: document.getElementById('selectedFileCard'),
      selectedFileName: document.getElementById('selectedFileName'),
      selectedFileSize: document.getElementById('selectedFileSize'),
      selectedFileType: document.getElementById('selectedFileType'),
      fileTypeIcon: document.getElementById('fileTypeIcon'),
      btnRemoveFile: document.getElementById('btnRemoveFile'),
      btnCancelSelection: document.getElementById('btnCancelSelection'),
      btnProcess: document.getElementById('btnProcess'),

      // Processing state
      processingHeader: document.getElementById('processingHeader'),
      processingSubheader: document.getElementById('processingSubheader'),
      processingStatusTag: document.getElementById('processingStatusTag'),
      processingJobId: document.getElementById('processingJobId'),
      processingElapsedTime: document.getElementById('processingElapsedTime'),
      btnCancelProcessing: document.getElementById('btnCancelProcessing'),
      stepUpload: document.getElementById('stepUpload'),
      stepQueue: document.getElementById('stepQueue'),
      stepExtract: document.getElementById('stepExtract'),
      stepPersist: document.getElementById('stepPersist'),

      // Result controls
      resultFileName: document.getElementById('resultFileName'),
      resultJobId: document.getElementById('resultJobId'),
      resultProviderBadge: document.getElementById('resultProviderBadge'),
      resultDuration: document.getElementById('resultDuration'),
      statCharCount: document.getElementById('statCharCount'),
      statWordCount: document.getElementById('statWordCount'),
      statLineCount: document.getElementById('statLineCount'),
      extractedTextContent: document.getElementById('extractedTextContent'),
      resultSearchInput: document.getElementById('resultSearchInput'),
      btnCopyText: document.getElementById('btnCopyText'),
      copyIcon: document.getElementById('copyIcon'),
      copyTextLabel: document.getElementById('copyTextLabel'),
      btnDownloadText: document.getElementById('btnDownloadText'),
      btnNewDocument: document.getElementById('btnNewDocument'),
      btnScrollToTop: document.getElementById('btnScrollToTop'),
    };
  }

  function bindEvents() {
    // Dropzone click & keyboard trigger
    if (el.dropZone && el.fileInput) {
      el.dropZone.addEventListener('click', () => el.fileInput.click());
      el.dropZone.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          el.fileInput.click();
        }
      });

      // File input change
      el.fileInput.addEventListener('change', (e) => {
        const file = e.target.files && e.target.files[0];
        if (file) {
          handleFileSelection(file);
        }
      });

      // Drag and Drop
      ['dragenter', 'dragover'].forEach((eventName) => {
        el.dropZone.addEventListener(eventName, (e) => {
          e.preventDefault();
          e.stopPropagation();
          el.dropZone.classList.add('drag-over');
        });
      });

      ['dragleave', 'dragend', 'drop'].forEach((eventName) => {
        el.dropZone.addEventListener(eventName, (e) => {
          e.preventDefault();
          e.stopPropagation();
          el.dropZone.classList.remove('drag-over');
        });
      });

      el.dropZone.addEventListener('drop', (e) => {
        const dt = e.dataTransfer;
        if (dt && dt.files && dt.files.length > 0) {
          handleFileSelection(dt.files[0]);
        }
      });
    }

    // Remove / Cancel selected file
    if (el.btnRemoveFile) el.btnRemoveFile.addEventListener('click', removeSelectedFile);
    if (el.btnCancelSelection) el.btnCancelSelection.addEventListener('click', removeSelectedFile);

    // Process button
    if (el.btnProcess) el.btnProcess.addEventListener('click', uploadAndProcess);

    // Copy result button
    if (el.btnCopyText) el.btnCopyText.addEventListener('click', copyExtractedText);

    // Download .txt button
    if (el.btnDownloadText) el.btnDownloadText.addEventListener('click', downloadExtractedText);

    // Process another / new document
    if (el.btnNewDocument) el.btnNewDocument.addEventListener('click', resetApplication);

    // Cancel in-progress processing
    if (el.btnCancelProcessing) el.btnCancelProcessing.addEventListener('click', handleCancelProcessing);

    // Scroll to top
    if (el.btnScrollToTop) {
      el.btnScrollToTop.addEventListener('click', () => {
        window.scrollTo({ top: 0, behavior: 'smooth' });
      });
    }

    // Search within extracted text
    if (el.resultSearchInput) {
      el.resultSearchInput.addEventListener('input', handleSearchInText);
    }

    // Close alert button
    if (el.btnCloseAlert) {
      el.btnCloseAlert.addEventListener('click', hideError);
    }
  }

  // =========================================================================
  // File Selection & Validation
  // =========================================================================

  function handleFileSelection(file) {
    hideError();
    const validation = validateFile(file);
    if (!validation.valid) {
      showError(validation.error, 'Invalid File');
      return;
    }

    state.selectedFile = file;
    renderSelectedFileInfo(file);
  }

  function validateFile(file) {
    if (!file) {
      return { valid: false, error: 'No file was selected.' };
    }

    if (file.size === 0) {
      return { valid: false, error: 'The selected file is empty (0 bytes).' };
    }

    if (file.size > CONFIG.MAX_FILE_SIZE_BYTES) {
      const maxMb = Math.round(CONFIG.MAX_FILE_SIZE_BYTES / (1024 * 1024));
      return {
        valid: false,
        error: `File size exceeds the ${maxMb} MB limit (${formatFileSize(file.size)}).`,
      };
    }

    const extension = getFileExtension(file.name);
    if (!CONFIG.ALLOWED_EXTENSIONS.includes(extension)) {
      return {
        valid: false,
        error: `Unsupported file type (.${extension}). Supported formats: ${CONFIG.ALLOWED_EXTENSIONS.join(', ').toUpperCase()}.`,
      };
    }

    return { valid: true };
  }

  function renderSelectedFileInfo(file) {
    if (!el.selectedFileCard) return;

    const ext = getFileExtension(file.name);
    if (el.selectedFileName) el.selectedFileName.textContent = file.name;
    if (el.selectedFileSize) el.selectedFileSize.textContent = formatFileSize(file.size);
    if (el.selectedFileType) el.selectedFileType.textContent = ext.toUpperCase();

    // Update icon based on type
    if (el.fileTypeIcon) {
      if (ext === 'pdf') {
        el.fileTypeIcon.className = 'bi bi-file-earmark-pdf-fill fs-3 text-danger';
      } else {
        el.fileTypeIcon.className = 'bi bi-file-earmark-image-fill fs-3 text-primary';
      }
    }

    el.selectedFileCard.classList.remove('d-none');
    if (el.dropZone) el.dropZone.classList.add('d-none');
  }

  function removeSelectedFile() {
    state.selectedFile = null;
    if (el.fileInput) el.fileInput.value = '';
    if (el.selectedFileCard) el.selectedFileCard.classList.add('d-none');
    if (el.dropZone) el.dropZone.classList.remove('d-none');
    hideError();
  }

  // =========================================================================
  // Upload & Asynchronous Dispatch
  // =========================================================================

  async function uploadAndProcess() {
    if (!state.selectedFile) {
      showError('Please select a document to process.', 'No Document Selected');
      return;
    }

    hideError();
    setButtonLoading(el.btnProcess, true, 'Uploading...');

    const formData = new FormData();
    formData.append('file', state.selectedFile);

    try {
      const response = await fetch(CONFIG.UPLOAD_ENDPOINT, {
        method: 'POST',
        body: formData,
      });

      const json = await response.json();

      if (!response.ok) {
        const errorDetail =
          json.message || json.detail || (json.errors && json.errors[0]) || 'Upload request failed.';
        showError(errorDetail, `Upload Failed (${response.status})`);
        setButtonLoading(el.btnProcess, false, 'Process Document');
        return;
      }

      const data = json.data || json;
      state.currentJobId = data.job_id;
      state.currentDocumentId = data.document_id;

      switchToProcessingView(data);
      startPolling(data.job_id);
    } catch (err) {
      showError(
        'Unable to contact server. Please verify your network connection and that the service is running.',
        'Network Error'
      );
      setButtonLoading(el.btnProcess, false, 'Process Document');
    }
  }

  // =========================================================================
  // Asynchronous Task Polling
  // =========================================================================

  function switchToProcessingView(data) {
    if (el.uploadSection) el.uploadSection.classList.add('d-none');
    if (el.resultSection) el.resultSection.classList.add('d-none');
    if (el.processingSection) el.processingSection.classList.remove('d-none');

    if (el.processingJobId) el.processingJobId.textContent = data.job_id || 'queued';
    if (el.processingStatusTag) el.processingStatusTag.textContent = 'queued';

    resetSteps();
    startElapsedTimer();
  }

  function startElapsedTimer() {
    stopElapsedTimer();
    state.elapsedSeconds = 0;
    if (el.processingElapsedTime) el.processingElapsedTime.textContent = '0s';

    state.elapsedTimer = setInterval(() => {
      state.elapsedSeconds += 1;
      if (el.processingElapsedTime) {
        el.processingElapsedTime.textContent = `${state.elapsedSeconds}s`;
      }
    }, 1000);
  }

  function stopElapsedTimer() {
    if (state.elapsedTimer) {
      clearInterval(state.elapsedTimer);
      state.elapsedTimer = null;
    }
  }

  function startPolling(jobId) {
    stopPolling();
    state.pollAttempts = 0;

    const poll = async () => {
      state.pollAttempts += 1;

      try {
        const response = await fetch(CONFIG.JOB_STATUS_ENDPOINT(jobId));
        if (!response.ok) {
          if (response.status === 404) {
            stopPolling();
            stopElapsedTimer();
            showError(`Job ${jobId} was not found on server.`, 'Job Not Found');
            resetApplication();
            return;
          }
          // Temporary server error, continue polling without timing out
          scheduleNextPoll(poll);
          return;
        }

        const json = await response.json();
        const jobData = json.data || json;
        const status = (jobData.status || '').toLowerCase();

        updateProcessingUIState(status, jobData);

        if (status === 'completed') {
          stopPolling();
          stopElapsedTimer();
          await fetchAndRenderResult(jobId);
        } else if (status === 'failed') {
          stopPolling();
          stopElapsedTimer();
          const reason = jobData.error || 'Document processing worker reported a failure.';
          showError(reason, 'Processing Failed');
          resetApplication();
        } else {
          // Still pending or processing - continue polling indefinitely until terminal status
          scheduleNextPoll(poll);
        }
      } catch (err) {
        // Network glitch during poll, try next interval
        scheduleNextPoll(poll);
      }
    };

    // Execute first check after 800ms
    state.pollTimer = setTimeout(poll, 800);
  }

  function scheduleNextPoll(pollFn) {
    state.pollTimer = setTimeout(pollFn, CONFIG.POLL_INTERVAL_MS);
  }

  function stopPolling() {
    if (state.pollTimer) {
      clearTimeout(state.pollTimer);
      state.pollTimer = null;
    }
  }

  function handleCancelProcessing() {
    stopPolling();
    stopElapsedTimer();
    resetApplication();
  }

  function updateProcessingUIState(status, jobData) {
    if (el.processingStatusTag) {
      if (jobData && jobData.attempts > 1 && status === 'processing') {
        el.processingStatusTag.textContent = `processing (attempt ${jobData.attempts})`;
      } else {
        el.processingStatusTag.textContent = status;
      }
    }

    if (status === 'pending' || status === 'queued') {
      setStepState(el.stepUpload, 'completed');
      setStepState(el.stepQueue, 'active');
      setStepState(el.stepExtract, 'pending');
      setStepState(el.stepPersist, 'pending');
      if (el.processingSubheader) {
        el.processingSubheader.textContent = 'Enqueued in Celery worker queue...';
      }
    } else if (status === 'processing') {
      setStepState(el.stepUpload, 'completed');
      setStepState(el.stepQueue, 'completed');
      setStepState(el.stepExtract, 'active');
      setStepState(el.stepPersist, 'pending');
      if (el.processingSubheader) {
        if (jobData && jobData.error && jobData.error.toLowerCase().includes('transient')) {
          el.processingSubheader.textContent = 'High AI model load encountered; worker is backing off & retrying automatically...';
        } else {
          el.processingSubheader.textContent = 'Google Gemini Multimodal OCR extracting text & tables...';
        }
      }
    } else if (status === 'completed') {
      setStepState(el.stepUpload, 'completed');
      setStepState(el.stepQueue, 'completed');
      setStepState(el.stepExtract, 'completed');
      setStepState(el.stepPersist, 'completed');
    }
  }

  function setStepState(stepElement, stateName) {
    if (!stepElement) return;
    stepElement.classList.remove('completed', 'active');
    if (stateName === 'completed') stepElement.classList.add('completed');
    if (stateName === 'active') stepElement.classList.add('active');
  }

  function resetSteps() {
    setStepState(el.stepUpload, 'completed');
    setStepState(el.stepQueue, 'active');
    setStepState(el.stepExtract, 'pending');
    setStepState(el.stepPersist, 'pending');
  }

  // =========================================================================
  // Result Retrieval & Display
  // =========================================================================

  async function fetchAndRenderResult(jobId) {
    try {
      const response = await fetch(CONFIG.JOB_RESULT_ENDPOINT(jobId));
      const json = await response.json();

      if (!response.ok) {
        showError('Could not retrieve final extracted text.', 'Result Fetch Failed');
        resetApplication();
        return;
      }

      const result = json.data || json;
      renderResultView(result);
    } catch (err) {
      showError('Failed to fetch processing result from server.', 'Network Error');
      resetApplication();
    }
  }

  function renderResultView(result) {
    if (el.processingSection) el.processingSection.classList.add('d-none');
    if (el.uploadSection) el.uploadSection.classList.add('d-none');
    if (el.resultSection) el.resultSection.classList.remove('d-none');

    state.extractedRawText = result.extracted_text || '';

    // Metadata
    if (el.resultFileName) {
      el.resultFileName.textContent = state.selectedFile ? state.selectedFile.name : 'Processed Document';
    }
    if (el.resultJobId) el.resultJobId.textContent = result.job_id || state.currentJobId;
    if (el.resultProviderBadge) el.resultProviderBadge.textContent = result.provider || 'gemini-3.6-flash';
    if (el.resultDuration) el.resultDuration.textContent = `${state.elapsedSeconds}s`;

    // Counts
    const text = state.extractedRawText;
    const charCount = text.length;
    const wordCount = text.trim() ? text.trim().split(/\s+/).length : 0;
    const lineCount = text ? text.split('\n').length : 0;

    if (el.statCharCount) el.statCharCount.textContent = charCount.toLocaleString();
    if (el.statWordCount) el.statWordCount.textContent = wordCount.toLocaleString();
    if (el.statLineCount) el.statLineCount.textContent = lineCount.toLocaleString();

    // Extracted content
    if (el.extractedTextContent) {
      el.extractedTextContent.textContent = text || '(No readable text could be extracted from this document)';
    }

    // Reset search
    if (el.resultSearchInput) el.resultSearchInput.value = '';

    // Scroll smoothly to results
    el.resultSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  // =========================================================================
  // Clipboard & Download Actions
  // =========================================================================

  async function copyExtractedText() {
    if (!state.extractedRawText) return;

    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(state.extractedRawText);
      } else {
        // Fallback for older browsers
        const textarea = document.createElement('textarea');
        textarea.value = state.extractedRawText;
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
      }

      // Visual feedback
      if (el.copyIcon && el.copyTextLabel) {
        el.copyIcon.className = 'bi bi-check2 text-success';
        el.copyTextLabel.textContent = 'Copied!';
        setTimeout(() => {
          el.copyIcon.className = 'bi bi-clipboard';
          el.copyTextLabel.textContent = 'Copy Text';
        }, 2000);
      }
    } catch (err) {
      showError('Unable to copy text to clipboard.', 'Clipboard Error');
    }
  }

  function downloadExtractedText() {
    if (!state.extractedRawText) return;

    const baseName = state.selectedFile ? state.selectedFile.name.replace(/\.[^/.]+$/, '') : 'extracted_text';
    const filename = `${baseName}_extracted.txt`;

    const blob = new Blob([state.extractedRawText], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  }

  function handleSearchInText(e) {
    const query = (e.target.value || '').trim();
    if (!el.extractedTextContent) return;

    if (!query) {
      el.extractedTextContent.textContent = state.extractedRawText;
      return;
    }

    const escaped = escapeHtml(state.extractedRawText);
    const regex = new RegExp(`(${escapeRegExp(query)})`, 'gi');
    const highlighted = escaped.replace(regex, '<mark>$1</mark>');
    el.extractedTextContent.innerHTML = highlighted;
  }

  // =========================================================================
  // Reset & UI State Helpers
  // =========================================================================

  function resetApplication() {
    stopPolling();
    stopElapsedTimer();

    state.selectedFile = null;
    state.currentJobId = null;
    state.currentDocumentId = null;
    state.extractedRawText = '';

    if (el.fileInput) el.fileInput.value = '';
    if (el.selectedFileCard) el.selectedFileCard.classList.add('d-none');
    if (el.dropZone) el.dropZone.classList.remove('d-none');
    if (el.processingSection) el.processingSection.classList.add('d-none');
    if (el.resultSection) el.resultSection.classList.add('d-none');
    if (el.uploadSection) el.uploadSection.classList.remove('d-none');

    setButtonLoading(el.btnProcess, false, 'Process Document');
  }

  function showError(message, title = 'Error') {
    if (!el.errorAlert) return;
    if (el.errorAlertTitle) el.errorAlertTitle.textContent = title;
    if (el.errorAlertMessage) el.errorAlertMessage.textContent = message;
    el.errorAlert.classList.remove('d-none');
    el.errorAlert.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  function hideError() {
    if (el.errorAlert) el.errorAlert.classList.add('d-none');
  }

  function setButtonLoading(button, isLoading, text) {
    if (!button) return;
    button.disabled = isLoading;
    if (isLoading) {
      button.innerHTML = `<span class="spinner-border spinner-border-sm me-2" role="status" aria-hidden="true"></span>${text}`;
    } else {
      button.innerHTML = `<span>${text}</span><i class="bi bi-arrow-right-short fs-5"></i>`;
    }
  }

  function getFileExtension(filename) {
    return (filename || '').split('.').pop().toLowerCase();
  }

  function formatFileSize(bytes) {
    if (bytes === 0) return '0 Bytes';
    const k = 1024;
    const sizes = ['Bytes', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
  }

  function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
  }

  function escapeRegExp(string) {
    return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
})();
