/**
 * @description Lightning Web Component for Salesforce Authenticator Registration
 * @author Your Name
 * @date 2026-02-08
 */
import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import isAuthenticatorRegistered from '@salesforce/apex/SalesforceAuthRegistrationController.isAuthenticatorRegistered';
import initiateAuthenticatorRegistration from '@salesforce/apex/SalesforceAuthRegistrationController.initiateAuthenticatorRegistration';
import verifyRegistration from '@salesforce/apex/SalesforceAuthRegistrationController.verifyRegistration';
import removeAuthenticatorRegistration from '@salesforce/apex/SalesforceAuthRegistrationController.removeAuthenticatorRegistration';

export default class SalesforceAuthRegistration extends LightningElement {
    /** Card title (configurable in App Builder for Community) */
    @api title = 'Setup Authenticator';

    isRegistered = false;
    isLoading = true;
    showRegistrationFlow = false;
    qrCodeUrl = '';
    registrationId = '';
    manualEntryKey = '';
    accountName = '';
    showManualEntry = false;
    registrationStep = 1; // 1: Initial, 2: QR Code, 3: Verification
    verificationCode = '';

    connectedCallback() {
        this.checkRegistrationStatus();
    }

    /**
     * Check if user already has authenticator registered
     */
    checkRegistrationStatus() {
        this.isLoading = true;
        isAuthenticatorRegistered()
            .then(result => {
                this.isRegistered = result;
                this.isLoading = false;
            })
            .catch(error => {
                this.showToast('Error', 'Failed to check registration status: ' + this.getErrorMessage(error), 'error');
                this.isLoading = false;
            });
    }

    /**
     * Start the registration process
     */
    handleStartRegistration() {
        this.isLoading = true;
        this.showRegistrationFlow = true;
        
        initiateAuthenticatorRegistration()
            .then(result => {
                if (result.success) {
                    this.qrCodeUrl = result.qrCodeUrl;
                    this.registrationId = result.registrationId;
                    this.manualEntryKey = result.manualEntryKey;
                    this.accountName = result.accountName;
                    this.registrationStep = 2;
                    this.isLoading = false;
                    
                    this.showToast('Success', 'QR Code generated. Please scan with Salesforce Authenticator app.', 'success');
                } else {
                    this.showToast('Error', result.errorMessage, 'error');
                    this.isLoading = false;
                    this.showRegistrationFlow = false;
                }
            })
            .catch(error => {
                this.showToast('Error', 'Failed to initiate registration: ' + this.getErrorMessage(error), 'error');
                this.isLoading = false;
                this.showRegistrationFlow = false;
            });
    }

    /**
     * Toggle manual entry key display
     */
    handleToggleManualEntry() {
        this.showManualEntry = !this.showManualEntry;
    }

    /**
     * Copy manual entry key to clipboard
     */
    handleCopyKey() {
        const keyElement = this.template.querySelector('.manual-entry-key');
        if (keyElement) {
            navigator.clipboard.writeText(this.manualEntryKey)
                .then(() => {
                    this.showToast('Success', 'Key copied to clipboard!', 'success');
                })
                .catch(() => {
                    this.showToast('Error', 'Failed to copy key', 'error');
                });
        }
    }

    /**
     * User indicates they've scanned the QR code
     */
    handleScannedQRCode() {
        this.registrationStep = 3;
        this.verificationCode = '';
    }

    /**
     * Handle verification code input
     */
    handleVerificationCodeChange(event) {
        const value = (event.detail.value || '').replace(/\D/g, '').slice(0, 6);
        this.verificationCode = value;
    }

    /**
     * Verify registration with the 6-digit code from the authenticator app
     */
    handleVerifyManually() {
        const code = (this.verificationCode || '').trim();
        if (code.length !== 6) {
            this.showToast('Invalid Code', 'Please enter the 6-digit code from your authenticator app.', 'warning');
            return;
        }

        this.isLoading = true;

        verifyRegistration({
            registrationId: this.registrationId,
            verificationCode: code
        })
            .then(result => {
                this.isLoading = false;

                if (result.success) {
                    this.isRegistered = true;
                    this.showRegistrationFlow = false;
                    this.registrationStep = 1;
                    this.verificationCode = '';
                    this.showToast('Success!', result.message, 'success');

                    this.dispatchEvent(new CustomEvent('registrationcomplete', {
                        detail: { registered: true }
                    }));
                } else {
                    this.showToast('Verification Failed', result.message, 'error');
                }
            })
            .catch(error => {
                this.isLoading = false;
                this.showToast('Error', 'Verification failed: ' + this.getErrorMessage(error), 'error');
            });
    }

    /**
     * Cancel registration process
     */
    handleCancelRegistration() {
        this.showRegistrationFlow = false;
        this.registrationStep = 1;
        this.qrCodeUrl = '';
        this.registrationId = '';
        this.manualEntryKey = '';
        this.verificationCode = '';
    }

    /**
     * Remove authenticator registration
     */
    handleRemoveRegistration() {
        if (!confirm('Are you sure you want to remove your Salesforce Authenticator? You will need to re-register.')) {
            return;
        }
        
        this.isLoading = true;
        
        removeAuthenticatorRegistration()
            .then(result => {
                if (result) {
                    this.isRegistered = false;
                    this.isLoading = false;
                    this.showToast('Success', 'Authenticator registration removed successfully.', 'success');
                    
                    this.dispatchEvent(new CustomEvent('registrationremoved', {
                        detail: { registered: false }
                    }));
                }
            })
            .catch(error => {
                this.isLoading = false;
                this.showToast('Error', 'Failed to remove registration: ' + this.getErrorMessage(error), 'error');
            });
    }

    /**
     * Show toast message
     */
    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        });
        this.dispatchEvent(event);
    }

    /**
     * Extract error message from error object
     */
    getErrorMessage(error) {
        if (error.body && error.body.message) {
            return error.body.message;
        } else if (error.message) {
            return error.message;
        }
        return 'Unknown error occurred';
    }

    // Computed properties for conditional rendering
    get manualEntryButtonLabel() {
        return this.showManualEntry ? 'Hide Manual Entry' : "Can't scan? Use manual entry";
    }

    get scannedCodeButtonLabel() {
        return "I've Scanned the Code";
    }

    get showInitialView() {
        return !this.showRegistrationFlow && !this.isRegistered;
    }

    get showRegisteredView() {
        return !this.showRegistrationFlow && this.isRegistered;
    }

    get showQRCodeStep() {
        return this.showRegistrationFlow && this.registrationStep === 2;
    }

    get showVerificationStep() {
        return this.showRegistrationFlow && this.registrationStep === 3;
    }

    get showQrLoading() {
        return this.isLoading && !this.qrCodeUrl;
    }

    get showQrUnavailable() {
        return !this.isLoading && !this.qrCodeUrl && this.showQRCodeStep;
    }
}
