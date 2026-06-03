/**
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 * <p>
 * http://www.apache.org/licenses/LICENSE-2.0
 * <p>
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.atlas.web.service;

import org.apache.atlas.AtlasConstants;
import org.apache.atlas.AtlasException;
import org.apache.commons.configuration2.Configuration;
import org.mockito.Mock;
import org.mockito.MockitoAnnotations;
import org.testng.annotations.BeforeMethod;
import org.testng.annotations.Test;

import static org.mockito.Mockito.when;
import static org.testng.Assert.assertEquals;
import static org.testng.Assert.assertFalse;
import static org.testng.Assert.assertNotNull;
import static org.testng.Assert.assertTrue;

/**
 * Unit tests for the active-active {@link ServiceState}.
 *
 * <p>There are no longer PASSIVE or BECOMING_PASSIVE states — every node transitions
 * directly BECOMING_ACTIVE → ACTIVE.
 */
public class ServiceStateTest {
    @Mock
    private Configuration configuration;

    @BeforeMethod
    public void setup() {
        MockitoAnnotations.openMocks(this);
        when(configuration.getString(AtlasConstants.ATLAS_MIGRATION_MODE_FILENAME, "")).thenReturn("");
    }

    @Test
    public void testInitialStateIsBecomingActive() {
        ServiceState serviceState = new ServiceState(configuration);

        assertEquals(serviceState.getState(), ServiceState.ServiceStateValue.BECOMING_ACTIVE,
                "Initial state must be BECOMING_ACTIVE in active-active mode");
    }

    @Test
    public void testDefaultConstructor() throws AtlasException {
        ServiceState serviceState = new ServiceState();
        assertNotNull(serviceState);
    }

    @Test
    public void testInitialStateIsMigratingWhenMigrationModeSet() {
        when(configuration.getString(AtlasConstants.ATLAS_MIGRATION_MODE_FILENAME, "")).thenReturn("migration.txt");

        ServiceState serviceState = new ServiceState(configuration);

        assertEquals(serviceState.getState(), ServiceState.ServiceStateValue.MIGRATING);
    }

    @Test
    public void testBecomingActive() {
        ServiceState serviceState = new ServiceState(configuration);

        serviceState.becomingActive();

        assertEquals(serviceState.getState(), ServiceState.ServiceStateValue.BECOMING_ACTIVE);
    }

    @Test
    public void testSetActive() {
        ServiceState serviceState = new ServiceState(configuration);

        serviceState.setActive();

        assertEquals(serviceState.getState(), ServiceState.ServiceStateValue.ACTIVE);
    }

    @Test
    public void testSetMigration() {
        ServiceState serviceState = new ServiceState(configuration);

        serviceState.setMigration();

        assertEquals(serviceState.getState(), ServiceState.ServiceStateValue.MIGRATING);
    }

    @Test
    public void testIsInstanceInTransition_trueWhenBecomingActive() {
        ServiceState serviceState = new ServiceState(configuration);

        // Initial state is BECOMING_ACTIVE
        assertTrue(serviceState.isInstanceInTransition(),
                "isInstanceInTransition() must be true while BECOMING_ACTIVE");
    }

    @Test
    public void testIsInstanceInTransition_falseWhenActive() {
        ServiceState serviceState = new ServiceState(configuration);
        serviceState.setActive();

        assertFalse(serviceState.isInstanceInTransition(),
                "isInstanceInTransition() must be false when ACTIVE");
    }

    @Test
    public void testIsActive_falseBeforeActivation() {
        ServiceState serviceState = new ServiceState(configuration);

        assertFalse(serviceState.isActive());
    }

    @Test
    public void testIsActive_trueAfterSetActive() {
        ServiceState serviceState = new ServiceState(configuration);
        serviceState.setActive();

        assertTrue(serviceState.isActive());
    }

    @Test
    public void testIsInstanceInMigration_true() {
        when(configuration.getString(AtlasConstants.ATLAS_MIGRATION_MODE_FILENAME, "")).thenReturn("migration.txt");

        ServiceState serviceState = new ServiceState(configuration);

        assertTrue(serviceState.isInstanceInMigration());
    }

    @Test
    public void testIsInstanceInMigration_false() {
        ServiceState serviceState = new ServiceState(configuration);

        assertFalse(serviceState.isInstanceInMigration());
    }

    @Test
    public void testGetStateName() {
        ServiceState serviceState = new ServiceState(configuration);

        assertEquals(serviceState.getStateName(), "BECOMING_ACTIVE");

        serviceState.setActive();

        assertEquals(serviceState.getStateName(), "ACTIVE");
    }

    @Test
    public void testInstanceIsActive_falseWhenBecomingActive() {
        ServiceState serviceState = new ServiceState(configuration);

        assertFalse(serviceState.isInstanceActive());
    }

    @Test
    public void testInstanceIsActive_trueAfterSetActive() {
        ServiceState serviceState = new ServiceState(configuration);
        serviceState.setActive();

        assertTrue(serviceState.isInstanceActive());
    }
}
