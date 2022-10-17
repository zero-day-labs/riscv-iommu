// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
//
// Edited by: Manuel Rodríguez <manuel.cederog@gmail.com>
// Edited at: 12/10/2022
//
// IOMMU Register field package: Contains SW access permissions

`ifndef IOMMU_FIELD_PKG_DEF
`define IOMMU_FIELD_PKG_DEF

package iommu_field_pkg;

    // SW access permissions specifier
    typedef enum logic [2:0] { 
        SwAccessRW  = 3'd0, // Read-write
        SwAccessRO  = 3'd1, // Read-only
        SwAccessWO  = 3'd2, // Write-only
        SwAccessW1C = 3'd3, // Write 1 to clear
        SwAccessW1S = 3'd4, // Write 1 to set
        SwAccessW0C = 3'd5, // Write 0 to clear
        SwAccessRC  = 3'd6  // Read to clear. Do not use, only exists for compatibility.
    } sw_access_e;

endpackage

`endif
