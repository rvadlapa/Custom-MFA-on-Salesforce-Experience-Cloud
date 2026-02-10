/**
 * @description Controller for Salesforce Authenticator registration using real Salesforce APIs
 * @author Your Name
 * @date 2026-02-08
 */
public with sharing class SalesforceAuthRegistrationController {
    
    // TOTP parameters
    private static final Integer TOTP_DIGITS = 6;
    private static final Integer TOTP_PERIOD = 30;
    private static final Integer SECRET_LENGTH = 20; // 160 bits for SHA1
    
    /**
     * @description Checks if the current user has Two-Factor Authentication registered
     * @return Boolean indicating registration status
     */
    @AuraEnabled(cacheable=true)
    public static Boolean isAuthenticatorRegistered() {
        try {
            String userId = UserInfo.getUserId();

            // Check standard TwoFactorInfo (native Salesforce MFA)
            List<TwoFactorInfo> twoFactorInfoList = [
                SELECT Id, Type, UserId
                FROM TwoFactorInfo
                WHERE UserId = :userId
                LIMIT 1
            ];
            if (!twoFactorInfoList.isEmpty()) {
                return true;
            }

            // Also check our custom MFA registration (so Remove shows correct state)
            List<MFA_Registration__c> completedRegistrations = [
                SELECT Id
                FROM MFA_Registration__c
                WHERE User__c = :userId
                AND Status__c = 'Completed'
                LIMIT 1
            ];
            return !completedRegistrations.isEmpty();
        } catch (Exception e) {
            throw new AuraHandledException('Error checking registration status: ' + e.getMessage());
        }
    }
    
    /**
     * @description Initiates Salesforce Authenticator registration for the current user
     * @return RegistrationResponse containing registration details
     */
    @AuraEnabled
    public static RegistrationResponse initiateAuthenticatorRegistration() {
        try {
            String userId = UserInfo.getUserId();
            User currentUser = [SELECT Name, Email, Username FROM User WHERE Id = :userId LIMIT 1];
            
            // Generate TOTP shared secret using Crypto class (returns hex string for storage)
            String sharedSecret = generateTotpSecret();
            // Base32 must encode the raw 20-byte secret, not the hex string's UTF-8 bytes
            Blob secretBlob = EncodingUtil.convertFromHex(sharedSecret);
            String base32Secret = encodeBase32(secretBlob);
            
            // Create QR code URL in standard TOTP format
            // Format: otpauth://totp/[Issuer]:[Account]?secret=[Secret]&issuer=[Issuer]
            String issuer = EncodingUtil.urlEncode('Salesforce', 'UTF-8');
            String account = EncodingUtil.urlEncode(currentUser.Email, 'UTF-8');
            String otpAuthUrl = 'otpauth://totp/' + issuer + ':' + account 
                              + '?secret=' + base32Secret 
                              + '&issuer=' + issuer
                              + '&algorithm=SHA1'
                              + '&digits=' + TOTP_DIGITS
                              + '&period=' + TOTP_PERIOD;
            
            // Fetch QR image server-side and return as data URI (CSP allows img-src data:)
            // Requires: Setup > Remote Site Settings > add https://api.qrserver.com
            String qrCodeUrl = fetchQrCodeAsDataUri(otpAuthUrl);
            
            // Generate unique registration ID
            String registrationId = generateRegistrationId();
            
            // Store the registration initialization (DML after callout)
            saveRegistrationAttempt(userId, registrationId, sharedSecret);
            
            RegistrationResponse response = new RegistrationResponse();
            response.qrCodeUrl = qrCodeUrl;
            response.registrationId = registrationId;
            response.manualEntryKey = base32Secret;
            response.accountName = currentUser.Name;
            response.userEmail = currentUser.Email;
            response.success = true;
            
            return response;
            
        } catch (Exception e) {
            RegistrationResponse response = new RegistrationResponse();
            response.success = false;
            response.errorMessage = 'Failed to initiate registration: ' + e.getMessage();
            return response;
        }
    }
    
    /**
     * @description Verifies the code entered by user to complete registration
     * @param registrationId The registration ID from initiation
     * @param verificationCode The 6-digit code from Authenticator app
     * @return VerificationResponse indicating successful verification
     */
    @AuraEnabled
    public static VerificationResponse verifyRegistration(String registrationId, String verificationCode) {
        try {
            String userId = UserInfo.getUserId();
            
            // Validate verification code format
            if (String.isBlank(verificationCode) || !verificationCode.isNumeric() || verificationCode.length() != TOTP_DIGITS) {
                VerificationResponse response = new VerificationResponse();
                response.success = false;
                response.message = 'Invalid verification code format. Please enter a ' + TOTP_DIGITS + '-digit code.';
                return response;
            }
            
            // Get the registration record to retrieve shared secret
            List<MFA_Registration__c> registrations = [
                SELECT Id, Shared_Secret__c, Status__c
                FROM MFA_Registration__c 
                WHERE Registration_Id__c = :registrationId 
                AND User__c = :userId
                AND Status__c = 'Pending'
                LIMIT 1
            ];
            
            if (registrations.isEmpty()) {
                VerificationResponse response = new VerificationResponse();
                response.success = false;
                response.message = 'Registration not found or already completed.';
                return response;
            }
            
            String sharedSecret = registrations[0].Shared_Secret__c;
            
            // Verify the TOTP code
            Boolean isValid = verifyTotpCode(sharedSecret, verificationCode);
            
            if (isValid) {
                // Registration is verified - update tracking record
                updateUserRegistrationStatus(userId, true, registrationId);
                
                VerificationResponse response = new VerificationResponse();
                response.success = true;
                response.message = 'Salesforce Authenticator registered successfully!';
                return response;
            } else {
                VerificationResponse response = new VerificationResponse();
                response.success = false;
                response.message = 'Invalid verification code. Please try again.';
                return response;
            }
            
        } catch (Exception e) {
            VerificationResponse response = new VerificationResponse();
            response.success = false;
            response.message = 'Verification failed: ' + e.getMessage();
            return response;
        }
    }
    
    /**
     * @description Verifies the current user's authenticator code (post-registration).
     * Use this when the user must prove they have the app (e.g. before a sensitive action).
     * @param verificationCode The 6-digit code from the authenticator app
     * @return VerificationResponse success true if code is valid
     */
    @AuraEnabled
    public static VerificationResponse verifyAuthenticatorCode(String verificationCode) {
        try {
            String userId = UserInfo.getUserId();

            if (String.isBlank(verificationCode) || !verificationCode.isNumeric() || verificationCode.length() != TOTP_DIGITS) {
                VerificationResponse response = new VerificationResponse();
                response.success = false;
                response.message = 'Please enter a valid 6-digit code from your authenticator app.';
                return response;
            }

            List<MFA_Registration__c> registrations = [
                SELECT Id, Shared_Secret__c
                FROM MFA_Registration__c
                WHERE User__c = :userId
                AND Status__c = 'Completed'
                ORDER BY Completion_Date__c DESC NULLS LAST
                LIMIT 1
            ];

            if (registrations.isEmpty()) {
                VerificationResponse response = new VerificationResponse();
                response.success = false;
                response.message = 'No authenticator registered. Please set up Salesforce Authenticator first.';
                return response;
            }

            String sharedSecret = registrations[0].Shared_Secret__c;
            if (String.isBlank(sharedSecret)) {
                VerificationResponse response = new VerificationResponse();
                response.success = false;
                response.message = 'Verification not available. Please re-register your authenticator.';
                return response;
            }

            Boolean isValid = verifyTotpCode(sharedSecret, verificationCode);
            VerificationResponse response = new VerificationResponse();
            if (isValid) {
                response.success = true;
                response.message = 'Verification successful.';
            } else {
                response.success = false;
                response.message = 'Invalid code. Please try again.';
            }
            return response;
        } catch (Exception e) {
            VerificationResponse response = new VerificationResponse();
            response.success = false;
            response.message = 'Verification failed: ' + e.getMessage();
            return response;
        }
    }

    /**
     * @description Removes Salesforce Authenticator registration
     * @return Boolean indicating successful removal
     */
    @AuraEnabled
    public static Boolean removeAuthenticatorRegistration() {
        try {
            String userId = UserInfo.getUserId();
            
            // Update tracking records to removed status
            updateUserRegistrationStatus(userId, false, null);
            
            return true;
            
        } catch (Exception e) {
            throw new AuraHandledException('Failed to remove registration: ' + e.getMessage());
        }
    }
    
    /**
     * @description Generates a cryptographically secure TOTP secret
     * @return String the generated secret
     */
    private static String generateTotpSecret() {
        // Generate 256 bits (32 bytes) so we have enough for 20-byte TOTP secret
        Blob randomBytes = Crypto.generateAesKey(256);
        String hexString = EncodingUtil.convertToHex(randomBytes);
        // Take first 20 bytes (160 bits) for SHA1 TOTP
        return hexString.substring(0, SECRET_LENGTH * 2);
    }
    
    /**
     * @description Encodes a Blob to Base32 string (required for TOTP)
     * @param input The input blob to encode
     * @return String Base32 encoded string
     */
    private static String encodeBase32(Blob input) {
        String base32Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
        String hex = EncodingUtil.convertToHex(input);
        String result = '';
        
        // Convert hex to binary string
        String binary = '';
        for (Integer i = 0; i < hex.length(); i++) {
            String hexChar = hex.substring(i, i + 1).toUpperCase();
            Integer val = '0123456789ABCDEF'.indexOf(hexChar);
            String binStr = '';
            for (Integer j = 3; j >= 0; j--) {
                binStr += ((val >> j) & 1) == 1 ? '1' : '0';
            }
            binary += binStr;
        }
        
        // Pad to multiple of 5
        while (Math.mod(binary.length(), 5) != 0) {
            binary += '0';
        }
        
        // Convert 5-bit groups to Base32 characters
        for (Integer i = 0; i < binary.length(); i += 5) {
            String chunk = binary.substring(i, Math.min(i + 5, binary.length()));
            Integer val = 0;
            for (Integer j = 0; j < chunk.length(); j++) {
                val = (val << 1) + (chunk.substring(j, j + 1) == '1' ? 1 : 0);
            }
            result += base32Chars.substring(val, val + 1);
        }
        
        return result;
    }
    
    /**
     * @description Verifies a TOTP code against the shared secret
     * @param secret The shared secret
     * @param code The code to verify
     * @return Boolean true if code is valid
     */
    private static Boolean verifyTotpCode(String secret, String code) {
        // Get current time counter
        Long currentTime = DateTime.now().getTime() / 1000;
        Long timeCounter = currentTime / TOTP_PERIOD;
        
        // Check current and adjacent time windows (allows for clock drift)
        for (Integer window = -1; window <= 1; window++) {
            String expectedCode = generateTotpCode(secret, timeCounter + window);
            if (expectedCode == code) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * @description Generates a TOTP code for a given time counter
     * @param secret The shared secret (hex string)
     * @param counter The time counter
     * @return String the 6-digit TOTP code
     */
    private static String generateTotpCode(String secret, Long counter) {
        // Convert counter to 8-byte big-endian
        String counterHex = '';
        Long tempCounter = counter;
        for (Integer i = 0; i < 8; i++) {
            counterHex = intToHex((Integer)Math.mod(tempCounter, 256)) + counterHex;
            tempCounter = tempCounter / 256;
        }
        
        Blob secretBlob = EncodingUtil.convertFromHex(secret);
        Blob counterBlob = EncodingUtil.convertFromHex(counterHex);
        
        // Generate HMAC-SHA1
        Blob hmacResult = Crypto.generateMac('HmacSHA1', counterBlob, secretBlob);
        String hmacHex = EncodingUtil.convertToHex(hmacResult);
        
        // Dynamic truncation
        // 0x0F = 15, 0x7FFFFFFF = 2147483647 (Apex doesn't support hex literals)
        Integer offset = Math.mod(hexToInt(hmacHex.substring(38, 40)), 16);
        String truncatedHex = hmacHex.substring(offset * 2, (offset * 2) + 8);
        Long truncatedValue = Math.mod(hexToLong(truncatedHex), 2147483648L);
        
        // Get last 6 digits
        Long otpValue = Math.mod(truncatedValue, (Long)Math.pow(10, TOTP_DIGITS));
        String otpString = String.valueOf(otpValue);
        
        // Pad with leading zeros if necessary
        while (otpString.length() < TOTP_DIGITS) {
            otpString = '0' + otpString;
        }
        
        return otpString;
    }
    
    /**
     * @description Converts an integer to a 2-character hex string
     * @param val The integer value
     * @return String hex representation
     */
    private static String intToHex(Integer val) {
        String hexChars = '0123456789abcdef';
        return hexChars.substring(val / 16, (val / 16) + 1) + hexChars.substring(Math.mod(val, 16), Math.mod(val, 16) + 1);
    }
    
    /**
     * @description Converts a hex string to integer
     * @param hex The hex string
     * @return Integer the integer value
     */
    private static Integer hexToInt(String hex) {
        String hexChars = '0123456789abcdef';
        Integer result = 0;
        hex = hex.toLowerCase();
        for (Integer i = 0; i < hex.length(); i++) {
            result = (result * 16) + hexChars.indexOf(hex.substring(i, i + 1));
        }
        return result;
    }
    
    /**
     * @description Converts a hex string to Long
     * @param hex The hex string
     * @return Long the long value
     */
    private static Long hexToLong(String hex) {
        String hexChars = '0123456789abcdef';
        Long result = 0;
        hex = hex.toLowerCase();
        for (Integer i = 0; i < hex.length(); i++) {
            result = (result * 16) + hexChars.indexOf(hex.substring(i, i + 1));
        }
        return result;
    }
    
    /**
     * @description Generates a unique registration ID
     * @return String unique registration ID
     */
    private static String generateRegistrationId() {
        Blob randomBlob = Crypto.generateAesKey(128);
        String hexString = EncodingUtil.convertToHex(randomBlob);
        return hexString.substring(0, 16);
    }

    /**
     * @description Fetches QR code image from API and returns as data URI (CSP-safe).
     * Requires: Setup > Security > Remote Site Settings > add https://api.qrserver.com
     * @param otpAuthUrl The otpauth:// URL to encode in the QR
     * @return String data:image/png;base64,... or empty string on failure
     */
    private static String fetchQrCodeAsDataUri(String otpAuthUrl) {
        try {
            String endpoint = 'https://api.qrserver.com/v1/create-qr-code/?size=200x200&data='
                + EncodingUtil.urlEncode(otpAuthUrl, 'UTF-8');
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setTimeout(120000);
            Http http = new Http();
            HttpResponse res = http.send(req);
            if (res.getStatusCode() == 200 && res.getBodyAsBlob() != null && res.getBodyAsBlob().size() > 0) {
                return 'data:image/png;base64,' + EncodingUtil.base64Encode(res.getBodyAsBlob());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'QR fetch failed (add api.qrserver.com to Remote Site Settings): ' + e.getMessage());
        }
        return '';
    }
    
    /**
     * @description Saves the registration attempt to custom object for tracking
     * @param userId User ID
     * @param registrationId Registration ID
     * @param sharedSecret The TOTP shared secret
     */
    private static void saveRegistrationAttempt(String userId, String registrationId, String sharedSecret) {
        try {
            MFA_Registration__c registration = new MFA_Registration__c(
                User__c = userId,
                Registration_Id__c = registrationId,
                Shared_Secret__c = sharedSecret,
                Registration_Date__c = System.now(),
                Status__c = 'Pending',
                Method__c = 'Salesforce Authenticator'
            );
            insert registration;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to save registration attempt: ' + e.getMessage());
        }
    }
    
    /**
     * @description Updates user's registration status
     * @param userId User ID
     * @param isRegistered Registration status
     * @param registrationId Registration ID
     */
    private static void updateUserRegistrationStatus(String userId, Boolean isRegistered, String registrationId) {
        try {
            // Update the registration record if exists
            if (registrationId != null) {
                List<MFA_Registration__c> registrations = [
                    SELECT Id, Status__c, Completion_Date__c
                    FROM MFA_Registration__c 
                    WHERE Registration_Id__c = :registrationId 
                    LIMIT 1
                ];
                
                if (!registrations.isEmpty()) {
                    registrations[0].Status__c = isRegistered ? 'Completed' : 'Removed';
                    registrations[0].Completion_Date__c = isRegistered ? System.now() : null;
                    update registrations[0];
                }
            } else if (!isRegistered) {
                // If no registration ID provided and removing, update all active registrations for user
                List<MFA_Registration__c> registrations = [
                    SELECT Id, Status__c
                    FROM MFA_Registration__c 
                    WHERE User__c = :userId
                    AND Status__c = 'Completed'
                ];
                
                for (MFA_Registration__c reg : registrations) {
                    reg.Status__c = 'Removed';
                }
                
                if (!registrations.isEmpty()) {
                    update registrations;
                }
            }
            
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to update registration status: ' + e.getMessage());
        }
    }
    
    /**
     * @description Wrapper class for registration response
     */
    public class RegistrationResponse {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String qrCodeUrl;
        @AuraEnabled public String registrationId;
        @AuraEnabled public String manualEntryKey;
        @AuraEnabled public String accountName;
        @AuraEnabled public String userEmail;
        @AuraEnabled public String errorMessage;
    }
    
    /**
     * @description Wrapper class for verification response
     */
    public class VerificationResponse {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
    }
}
