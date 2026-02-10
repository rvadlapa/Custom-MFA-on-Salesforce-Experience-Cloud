/**
 * @description Verify identity using the 6-digit code from Salesforce Authenticator.
 * Use after registration when the user must prove they have the app.
 */
import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import verifyAuthenticatorCode from '@salesforce/apex/SalesforceAuthRegistrationController.verifyAuthenticatorCode';

export default class AuthenticatorVerify extends LightningElement {
    @api title = 'Verify Your Identity';

    verificationCode = '';
    isLoading = false;

    handleCodeChange(event) {
        const value = (event.detail.value || '').replace(/\D/g, '').slice(0, 6);
        this.verificationCode = value;
    }

    handleVerify() {
        const code = (this.verificationCode || '').trim();
        if (code.length !== 6) {
            this.showToast('Invalid Code', 'Please enter the 6-digit code from your authenticator app.', 'warning');
            return;
        }

        this.isLoading = true;
        verifyAuthenticatorCode({ verificationCode: code })
            .then((result) => {
                this.isLoading = false;
                if (result.success) {
                    this.showToast('Verified', result.message, 'success');
                    this.verificationCode = '';
                    this.dispatchEvent(new CustomEvent('verified', { detail: { verified: true } }));
                } else {
                    this.showToast('Verification Failed', result.message, 'error');
                }
            })
            .catch((error) => {
                this.isLoading = false;
                this.showToast('Error', this.getErrorMessage(error), 'error');
            });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    getErrorMessage(error) {
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        return 'An unexpected error occurred';
    }
}
