import EmployeeAccessPanel from './employee-access-panel';

export default function EmployeesPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold font-heading">Employee Management</h1>
        <p className="text-sm text-muted-foreground">
          Manage store employee accounts, roles, permissions, and activity.
        </p>
      </div>
      <EmployeeAccessPanel />
    </div>
  );
}
