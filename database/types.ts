/**
 * TypeScript types for bike benefits status tracking
 * Auto-generated from Supabase schema
 * 
 * Usage:
 * Import these types in your frontend application to get type safety
 * when working with bike benefits and contracts
 */

// ============================================
// Enums
// ============================================

export type BenefitStatus = 
  | 'inactive'          // Default when benefit is created (step is NULL)
  | 'searching'         // Employee is choosing a bike (step = 'choose_bike')
  | 'testing'           // Employee is testing a bike (step = 'book_live_test' + WhatsApp sent)
  | 'active'            // Bike delivered and benefit is active (step = 'pickup_delivery' + delivered)
  | 'insurance_claim'   // Insurance claim filed (manually set by HR)
  | 'terminated';       // Benefit terminated (manually set by HR)

export type ContractStatus = 
  | 'not_started'            // Contract not yet generated
  | 'viewed_by_employee'     // Employee has viewed the contract
  | 'signed_by_employee'     // Employee has signed
  | 'signed_by_employer'     // Employer has signed (after employee)
  | 'approved'               // Both parties signed, fully executed
  | 'terminated';            // Contract terminated by HR

export type BikeStep = 
  | 'choose_bike'
  | 'book_live_test'
  | 'commit_to_bike'
  | 'sign_contract'
  | 'pickup_delivery';

export type ProfileStatus = 'active' | 'inactive';

export type BikeType = 
  | 'e_mtb_hardtail_29'
  | 'e_mtb_hardtail_27_5'
  | 'e_full_suspension_29'
  | 'e_full_suspension_27_5'
  | 'e_city_bike'
  | 'e_touring'
  | 'e_road_race'
  | 'e_cargo_bike'
  | 'e_kids_24';

// ============================================
// Database Tables
// ============================================

export interface BikeBenefit {
  id: string;
  user_id: string;
  bike_id: string | null;
  
  // Workflow tracking
  step: BikeStep | null;
  
  // Status fields
  benefit_status: BenefitStatus | null;
  contract_status: ContractStatus;
  
  // Live test details
  live_test_location: string | null;
  live_test_lat: number | null;
  live_test_lon: number | null;
  live_test_location_name: string | null;
  live_test_sent_at: string | null;
  live_test_checked_in_at: string | null;
  
  // Commitment
  committed_at: string | null;
  checked_in_at: string | null;
  
  // Contract timestamps
  contract_requested_at: string | null;
  contract_viewed_at: string | null;
  contract_employee_signed_at: string | null;
  contract_employer_signed_at: string | null;
  contract_approved_at: string | null;
  contract_terminated_at: string | null;
  
  // Delivery
  delivered_at: string | null;
  
  // Benefit status timestamps
  benefit_terminated_at: string | null;
  benefit_insurance_claim_at: string | null;
  
  // Metadata
  created_at: string;
  updated_at: string;
}

export interface Bike {
  id: string;
  name: string;
  type: BikeType | null;
  brand: string | null;
  description: string | null;
  image_url: string | null;
  
  // Pricing
  full_price: number;
  employee_price: number | null;
  
  // Specifications
  weight_kg: number | null;
  charge_time_hours: number | null;
  range_max_km: number | null;
  power_wh: number | null;
  engine: string | null;
  supported_features: string | null;
  frame_material: string | null;
  frame_size: string | null;
  wheel_size: string | null;
  wheel_bandwidth: string | null;
  lock_type: string | null;
  sku: string | null;
  
  // Dealer info
  dealer_name: string | null;
  dealer_address: string | null;
  dealer_lat: number | null;
  dealer_lon: number | null;
  
  // Availability
  available_for_test: boolean;
  in_stock: boolean;
  
  created_at: string;
  updated_at: string;
}

export interface Profile {
  user_id: string;
  email: string;
  status: ProfileStatus;
  company_id: string;
  first_name: string;
  last_name: string;
  description: string | null;
  department: string | null;
  hire_date: number | null; // Unix timestamp in milliseconds
  created_at: string;
}

export interface Company {
  id: string;
  name: string;
  monthly_benefit_subsidy: number;
  contract_months: number;
  days_in_office: number;
  created_at: string;
  updated_at: string;
}

// ============================================
// Views
// ============================================

export interface ProfileInviteWithDetails {
  // Invite data
  invite_id: string;
  email: string;
  invite_status: ProfileStatus;
  invited_at: string;
  
  // Company data
  company_id: string;
  company_name: string;
  monthly_benefit_subsidy: number;
  contract_months: number;
  
  // Profile data (null if not registered)
  user_id: string | null;
  profile_status: ProfileStatus | null;
  registered_at: string | null;
  
  // Employee data (first_name and last_name are always present, others nullable)
  first_name: string;
  last_name: string;
  description: string | null;
  department: string | null;
  hire_date: number | null;
  
  // Benefit data (null if not started)
  bike_benefit_id: string | null;
  current_step: BikeStep | null;
  
  // Status fields (benefit_status is NULL when benefit not yet started)
  benefit_status: BenefitStatus | null;
  contract_status: ContractStatus | null;
  
  // Bike data
  bike_id: string | null;
  bike_name: string | null;
  bike_brand: string | null;
  bike_type: BikeType | null;
  bike_full_price: number | null;
  bike_employee_price: number | null;
  monthly_benefit_price: number;
  
  // Progress timestamps
  committed_at: string | null;
  delivered_at: string | null;
  benefit_terminated_at: string | null;
  benefit_insurance_claim_at: string | null;
  
  // Contract timestamps
  contract_requested_at: string | null;
  contract_viewed_at: string | null;
  contract_employee_signed_at: string | null;
  contract_employer_signed_at: string | null;
  contract_approved_at: string | null;
  contract_terminated_at: string | null;
  
  // Test location
  live_test_lat: number | null;
  live_test_lon: number | null;
  live_test_location_name: string | null;
  live_test_sent_at: string | null;
  live_test_checked_in_at: string | null;
  
  // Order details
  order_id: string | null;
  ordered_helmet: boolean | null;
  ordered_insurance: boolean | null;
}

// ============================================
// API Response Types
// ============================================

export interface BenefitStatusSummary {
  status: BenefitStatus;
  count: number;
}

export interface ContractStatusSummary {
  status: ContractStatus;
  count: number;
}

// ============================================
// Helper Types
// ============================================

export interface BenefitStatusConfig {
  label: string;
  color: 'gray' | 'blue' | 'orange' | 'green' | 'red' | 'darkgray';
  description: string;
}

export interface ContractStatusConfig {
  label: string;
  color: 'gray' | 'blue' | 'lightblue' | 'yellow' | 'green' | 'red';
  description: string;
}

// ============================================
// Status Configuration Maps
// ============================================

export const BENEFIT_STATUS_CONFIG: Record<BenefitStatus, BenefitStatusConfig> = {
  inactive: {
    label: 'Inactive',
    color: 'gray',
    description: 'Benefit created but not yet started'
  },
  searching: {
    label: 'Searching',
    color: 'blue',
    description: 'Employee is browsing and choosing bikes'
  },
  testing: {
    label: 'Testing',
    color: 'orange',
    description: 'Employee has booked a live test'
  },
  active: {
    label: 'Active',
    color: 'green',
    description: 'Bike delivered, benefit is active'
  },
  insurance_claim: {
    label: 'Insurance Claim',
    color: 'red',
    description: 'Insurance claim has been filed'
  },
  terminated: {
    label: 'Terminated',
    color: 'darkgray',
    description: 'Benefit has been terminated'
  }
};

export const CONTRACT_STATUS_CONFIG: Record<ContractStatus, ContractStatusConfig> = {
  not_started: {
    label: 'Not Started',
    color: 'gray',
    description: 'Contract not yet generated'
  },
  viewed_by_employee: {
    label: 'Viewed by Employee',
    color: 'blue',
    description: 'Employee has viewed the contract'
  },
  signed_by_employee: {
    label: 'Signed by Employee',
    color: 'lightblue',
    description: 'Employee has signed the contract'
  },
  signed_by_employer: {
    label: 'Signed by Employer',
    color: 'yellow',
    description: 'Employer has signed the contract'
  },
  approved: {
    label: 'Approved',
    color: 'green',
    description: 'Contract fully executed by both parties'
  },
  terminated: {
    label: 'Terminated',
    color: 'red',
    description: 'Contract has been terminated'
  }
};

// ============================================
// Type Guards
// ============================================

export function isBenefitStatus(value: string): value is BenefitStatus {
  return ['inactive', 'searching', 'testing', 'active', 'insurance_claim', 'terminated'].includes(value);
}

export function isContractStatus(value: string): value is ContractStatus {
  return ['not_started', 'viewed_by_employee', 'signed_by_employee', 'signed_by_employer', 'approved', 'terminated'].includes(value);
}

// ============================================
// Utility Functions
// ============================================

/**
 * Get the display configuration for a benefit status
 */
export function getBenefitStatusConfig(status: BenefitStatus): BenefitStatusConfig {
  return BENEFIT_STATUS_CONFIG[status];
}

/**
 * Get the display configuration for a contract status
 */
export function getContractStatusConfig(status: ContractStatus): ContractStatusConfig {
  return CONTRACT_STATUS_CONFIG[status];
}

/**
 * Check if a benefit is in a terminal state (cannot progress further)
 */
export function isBenefitTerminal(status: BenefitStatus | null): boolean {
  if (!status) return false;
  return status === 'active' || status === 'terminated';
}

/**
 * Check if a contract is in a terminal state
 */
export function isContractTerminal(status: ContractStatus): boolean {
  return status === 'approved' || status === 'terminated';
}

/**
 * Get the next expected contract status
 */
export function getNextContractStatus(current: ContractStatus): ContractStatus | null {
  const flow: Record<ContractStatus, ContractStatus | null> = {
    not_started: 'viewed_by_employee',
    viewed_by_employee: 'signed_by_employee',
    signed_by_employee: 'signed_by_employer',
    signed_by_employer: 'approved',
    approved: null,
    terminated: null
  };
  
  return flow[current];
}

/**
 * Format contract status for display
 */
export function formatContractStatus(status: ContractStatus): string {
  return CONTRACT_STATUS_CONFIG[status].label;
}

/**
 * Format benefit status for display
 */
export function formatBenefitStatus(status: BenefitStatus | null): string {
  if (!status) return 'Not Started';
  return BENEFIT_STATUS_CONFIG[status].label;
}
