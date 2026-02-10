import { LightningElement, track, api } from 'lwc';
import sendVerificationCode from '@salesforce/apex/PhoneVerificationController.sendVerificationCode';
import verifyCode from '@salesforce/apex/PhoneVerificationController.verifyCode';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class PhoneVerification extends LightningElement {
    @api title;
    @track phoneNumber = '';
    @track verificationCode = '';
    @track codeSent = false;
    @track verificationSuccess = false;
    @track isLoading = false;
    @track errorMessage = '';

    handlePhoneChange(event) {
        this.phoneNumber = event.target.value;
        this.errorMessage = '';
    }

    handleCodeChange(event) {
        this.verificationCode = event.target.value;
        this.errorMessage = '';
    }

    handleSendCode() {
        if (!this.validatePhoneNumber()) {
            return;
        }

        this.isLoading = true;
        this.errorMessage = '';

        sendVerificationCode({ phoneNumber: this.phoneNumber })
            .then(() => {
                this.codeSent = true;
                this.showToast('Success', 'Verification code sent to your phone', 'success');
            })
            .catch(error => {
                this.errorMessage = this.getErrorMessage(error);
                this.showToast('Error', this.errorMessage, 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleVerifyCode() {
        if (!this.verificationCode || this.verificationCode.length !== 6) {
            this.errorMessage = 'Please enter a valid 6-digit code';
            return;
        }

        this.isLoading = true;
        this.errorMessage = '';

        verifyCode({ 
            phoneNumber: this.phoneNumber, 
            enteredCode: this.verificationCode 
        })
            .then(isValid => {
                if (isValid) {
                    this.verificationSuccess = true;
                    this.showToast('Success', 'Phone number verified successfully!', 'success');
                    
                    // Dispatch custom event for parent component
                    this.dispatchEvent(new CustomEvent('verified', {
                        detail: { phoneNumber: this.phoneNumber }
                    }));
                    
                    // Optional: Redirect or perform other actions
                    // window.location.href = '/success-page';
                } else {
                    this.errorMessage = 'Invalid verification code. Please try again.';
                    this.showToast('Error', this.errorMessage, 'error');
                }
            })
            .catch(error => {
                this.errorMessage = this.getErrorMessage(error);
                this.showToast('Error', this.errorMessage, 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleResendCode() {
        this.verificationCode = '';
        this.handleSendCode();
    }

    handleChangePhone() {
        this.codeSent = false;
        this.verificationCode = '';
        this.phoneNumber = '';
        this.errorMessage = '';
        this.verificationSuccess = false;
    }

    validatePhoneNumber() {
        const phoneRegex = /^\+?[1-9]\d{1,14}$/;
        
        if (!this.phoneNumber) {
            this.errorMessage = 'Please enter a phone number';
            return false;
        }
        
        if (!phoneRegex.test(this.phoneNumber.replace(/[\s-]/g, ''))) {
            this.errorMessage = 'Please enter a valid phone number with country code (e.g., +1234567890)';
            return false;
        }
        
        return true;
    }

    getErrorMessage(error) {
        if (error.body && error.body.message) {
            return error.body.message;
        } else if (error.message) {
            return error.message;
        }
        return 'An unexpected error occurred';
    }

    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        });
        this.dispatchEvent(event);
    }
}
